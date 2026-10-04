import { describe, expect, it } from "bun:test";
import { type } from "@oh-my-pi/omptype";
import { agentLoop } from "@oh-my-pi/pi-agent-core/agent-loop";
import type {
	AgentContext,
	AgentLoopConfig,
	AgentMessage,
	AgentTool,
	StreamFn,
} from "@oh-my-pi/pi-agent-core/types";
import type {
	AssistantMessage,
	Context,
	Message,
	NInferToolCallRecovery,
	TextContent,
	ToolCall,
} from "@oh-my-pi/pi-ai";
import { createMockModel } from "@oh-my-pi/pi-ai/providers/mock";
import { AssistantMessageEventStream } from "@oh-my-pi/pi-ai/utils/event-stream";
import { createAssistantMessage, createUserMessage } from "./helpers";

// =============================================================================
// Scripted NInfer provider stand-in
// =============================================================================

interface ScriptedTurn {
	/** Text content of the turn (a rejected raw tool-call markup or plain prose). */
	text?: string;
	/** A valid structured tool call. */
	toolCall?: { name: string; arguments: Record<string, unknown> };
	/** NInfer terminal diagnostic extension; absent for turns without one. */
	recovery?: NInferToolCallRecovery;
}

interface ScriptedProvider {
	/** The streamFn handed to the agent loop; one scripted turn per provider call. */
	readonly streamFn: StreamFn;
	/** The provider-visible context at each call, in call order (one entry per call). */
	readonly providerContexts: Message[][];
}

const READ_MARKUP_PATH2 =
	"<tool_call><function=read><parameter=path>E:/KI/ninfer-custom/README.md</parameter><parameter=path2>5-20</parameter></function></tool_call>";
const GLOB_MARKUP_PATTERN =
	"<tool_call><function=glob><parameter>limit>5</parameter><parameter>pattern>src/*.cpp</parameter></function></tool_call>";
const FENCED_LITERAL = "```\n<tool_call>\n<function=read>\n</function>\n</tool_call>\n```";

const READ_RECOVERY: NInferToolCallRecovery = {
	retry_eligible: true,
	fallback_reason: "ambiguous_structure",
	ambiguity_cause: "undeclared_parameter",
	tool_name: "read",
	parameter_names: ["path2"],
	parameter_count: 1,
	parameter_names_truncated: false,
};

const GLOB_RECOVERY: NInferToolCallRecovery = {
	retry_eligible: true,
	fallback_reason: "ambiguous_structure",
	ambiguity_cause: "undeclared_parameter",
	tool_name: "glob",
	parameter_names: ["pattern"],
	parameter_count: 1,
	parameter_names_truncated: false,
};

// stage2_value_boundary is retry-ineligible: the parser saw a value-boundary
// ambiguity it will not classify further, so the agent loop must not retry.
const STAGE2_RECOVERY: NInferToolCallRecovery = {
	retry_eligible: false,
	fallback_reason: "ambiguous_structure",
	ambiguity_cause: "stage2_value_boundary",
	tool_name: null,
	parameter_names: [],
	parameter_count: 0,
	parameter_names_truncated: false,
};

/** Build the assistant event stream for one scripted turn, NInfer-shaped. */
function emitTurn(stream: AssistantMessageEventStream, turn: ScriptedTurn): void {
	const content: AssistantMessage["content"] = [];
	if (turn.text !== undefined) content.push({ type: "text", text: turn.text });
	if (turn.toolCall) {
		content.push({
			type: "toolCall",
			id: `call_${turn.toolCall.name}`,
			name: turn.toolCall.name,
			arguments: turn.toolCall.arguments,
		} as ToolCall);
	}
	const partial = {
		...createAssistantMessage(content, turn.toolCall ? "toolUse" : "stop"),
		provider: "ninfer",
		...(turn.recovery ? { ninferToolCallRecovery: turn.recovery } : {}),
	};
	stream.push({ type: "start", partial });
	let contentIndex = 0;
	for (const block of partial.content) {
		if (block.type === "text") {
			stream.push({ type: "text_start", contentIndex, partial });
			stream.push({ type: "text_delta", contentIndex, delta: block.text, partial });
			stream.push({ type: "text_end", contentIndex, content: block.text, partial });
		} else if (block.type === "toolCall") {
			stream.push({ type: "toolcall_start", contentIndex, partial });
			stream.push({ type: "toolcall_delta", contentIndex, delta: JSON.stringify(block.arguments), partial });
			stream.push({ type: "toolcall_end", contentIndex, toolCall: block, partial });
		}
		contentIndex++;
	}
	stream.push({ type: "done", reason: partial.stopReason as "stop" | "length" | "toolUse", message: partial });
}

function makeScriptedProvider(script: ScriptedTurn[]): ScriptedProvider {
	let turn = 0;
	const providerContexts: Message[][] = [];
	const streamFn: StreamFn = (model, context) => {
		providerContexts.push([...context.messages]);
		const scripted = script[turn++] ?? { text: "done" };
		const stream = new AssistantMessageEventStream();
		queueMicrotask(() => emitTurn(stream, scripted));
		return stream;
	};
	return { streamFn, providerContexts };
}

// =============================================================================
// Tools and helpers
// =============================================================================

/** Read tool recording each executed payload. */
function makeReadTool(executions: unknown[]): AgentTool {
	const toolSchema = type({ path: "string" });
	const tool: AgentTool<typeof toolSchema> = {
		name: "read",
		label: "Read",
		description: "Read a file",
		parameters: toolSchema,
		async execute(_toolCallId, params) {
			executions.push(params);
			return {
				content: [{ type: "text", text: `contents: ${params.path}` }],
				details: params,
			};
		},
	};
	return tool;
}

/** Glob tool recording each executed payload. */
function makeGlobTool(executions: unknown[]): AgentTool {
	const toolSchema = type({ path: "string?", limit: "number?" });
	const tool: AgentTool<typeof toolSchema> = {
		name: "glob",
		label: "Glob",
		description: "Find files",
		parameters: toolSchema,
		async execute(_toolCallId, params) {
			executions.push(params);
			return {
				content: [{ type: "text", text: `matches: ${JSON.stringify(params)}` }],
				details: params,
			};
		},
	};
	return tool;
}

/** All assistant text in a run, in order. */
function assistantTexts(messages: AgentMessage[]): string[] {
	const out: string[] = [];
	for (const message of messages) {
		if (message.role !== "assistant") continue;
		for (const block of message.content) {
			if (block.type === "text") out.push((block as TextContent).text);
		}
	}
	return out;
}

/** Developer-message texts (the correction context is a developer message). */
function developerTexts(messages: AgentMessage[]): string[] {
	const out: string[] = [];
	for (const message of messages) {
		if (message.role !== "developer") continue;
		const blocks = Array.isArray(message.content) ? message.content : [message.content];
		for (const block of blocks) {
			if (typeof block === "string") out.push(block);
			else if (block.type === "text") out.push(block.text);
		}
	}
	return out;
}

// =============================================================================
// Spec §9.4 cases
// =============================================================================

describe("NInfer parser-recovery retry guard (R17-02B/C)", () => {
	const mock = createMockModel({ responses: [] });

	async function run(
		tools: AgentTool[],
		script: ScriptedTurn[],
	): Promise<{ messages: AgentMessage[]; provider: ScriptedProvider }> {
		const provider = makeScriptedProvider(script);
		const context: AgentContext = { systemPrompt: [""], messages: [], tools };
		const config: AgentLoopConfig = {
			model: mock.model,
			convertToLlm: (messages: AgentMessage[]) =>
				messages.filter(m => m.role === "user" || m.role === "assistant" || m.role === "toolResult") as Message[],
		};
		const messages = await agentLoop([createUserMessage("go")], context, config, undefined, provider.streamFn).result();
		return { messages, provider };
	}

	it("case 1: invalid read/path2 then valid → exactly one retry, then the tool executes", async () => {
		const executions: unknown[] = [];
		const { messages, provider } = await run([makeReadTool(executions)], [
			{ text: READ_MARKUP_PATH2, recovery: READ_RECOVERY },
			{ toolCall: { name: "read", arguments: { path: "E:/KI/ninfer-custom/README.md" } } },
			{ text: "Read the README." },
		]);

		expect(provider.providerContexts).toHaveLength(3);
		expect(executions).toEqual([{ path: "E:/KI/ninfer-custom/README.md" }]);
		// The rejected turn is discarded from the returned run messages.
		expect(assistantTexts(messages)).not.toContain(READ_MARKUP_PATH2);
		// The correction context is injected: bounded diagnostic text, no raw markup.
		const correction = developerTexts(messages);
		expect(correction).toHaveLength(1);
		expect(correction[0]).toContain("path2");
		expect(correction[0]).toContain("parameter names declared in the supplied tool schema");
		expect(correction[0]).not.toContain(READ_MARKUP_PATH2);
		// The provider never replays the rejected markup: turn 2's context carries no
		// assistant message at all (the identity converter drops the developer correction).
		expect(provider.providerContexts[1]?.some(m => m.role === "assistant")).toBe(false);
	});

	it("case 2: invalid glob/pattern then valid → exactly one retry", async () => {
		const executions: unknown[] = [];
		const { messages, provider } = await run([makeGlobTool(executions)], [
			{ text: GLOB_MARKUP_PATTERN, recovery: GLOB_RECOVERY },
			{ toolCall: { name: "glob", arguments: { limit: 5 } } },
			{ text: "Found the files." },
		]);

		expect(provider.providerContexts).toHaveLength(3);
		expect(executions).toEqual([{ limit: 5 }]);
		expect(assistantTexts(messages)).not.toContain(GLOB_MARKUP_PATTERN);
		const correction = developerTexts(messages);
		expect(correction).toHaveLength(1);
		expect(correction[0]).toContain("pattern");
	});

	it("case 3: invalid twice → one retry only, then a controlled failure (no spin)", async () => {
		const executions: unknown[] = [];
		const { messages, provider } = await run([makeReadTool(executions)], [
			{ text: READ_MARKUP_PATH2, recovery: READ_RECOVERY },
			{ text: READ_MARKUP_PATH2, recovery: READ_RECOVERY },
		]);

		// Exactly one retry: two model calls total, then the run ends.
		expect(provider.providerContexts).toHaveLength(2);
		expect(executions).toHaveLength(0);
		const last = messages[messages.length - 1] as AssistantMessage;
		expect(last.role).toBe("assistant");
		expect(last.stopReason).toBe("error");
		expect(last.errorMessage).toContain("Tool call generation failed");
		expect(last.errorMessage).toContain("path2");
		// No further model turns and no user-equivalent continue turn.
		expect(messages.filter(m => m.role === "user")).toHaveLength(1);
	});

	it("case 4: fenced literal <tool_call> with no diagnostic → zero retries", async () => {
		const executions: unknown[] = [];
		const { messages, provider } = await run([makeReadTool(executions)], [{ text: FENCED_LITERAL }]);

		expect(provider.providerContexts).toHaveLength(1);
		expect(executions).toHaveLength(0);
		expect(assistantTexts(messages)).toContain(FENCED_LITERAL);
	});

	it("case 5: stage2_value_boundary (retry_eligible false) → zero retries", async () => {
		const executions: unknown[] = [];
		const { messages, provider } = await run([makeReadTool(executions)], [
			{ text: READ_MARKUP_PATH2, recovery: STAGE2_RECOVERY },
		]);

		expect(provider.providerContexts).toHaveLength(1);
		expect(executions).toHaveLength(0);
		const last = messages[messages.length - 1] as AssistantMessage;
		expect(last.stopReason).toBe("stop");
		expect(last.errorMessage).toBeUndefined();
		// The rejected turn stays in the history as an ordinary text turn (no
		// diagnostic means nothing was discarded).
		expect(assistantTexts(messages)).toContain(READ_MARKUP_PATH2);
	});

	it("case 6: normal prose answer → zero retries", async () => {
		const executions: unknown[] = [];
		const { messages, provider } = await run([makeReadTool(executions)], [{ text: "All done, no tools needed." }]);

		expect(provider.providerContexts).toHaveLength(1);
		expect(executions).toHaveLength(0);
		expect(developerTexts(messages)).toHaveLength(0);
	});

	it("case 7: valid tool call → zero retries, tool executes once", async () => {
		const executions: unknown[] = [];
		const { messages, provider } = await run([makeReadTool(executions)], [
			{ toolCall: { name: "read", arguments: { path: "E:/KI/ninfer-custom/README.md" } } },
			{ text: "Read the README." },
		]);

		expect(provider.providerContexts).toHaveLength(2);
		expect(executions).toEqual([{ path: "E:/KI/ninfer-custom/README.md" }]);
		expect(developerTexts(messages)).toHaveLength(0);
	});

	it("case 8: the rejected turn is not installed as an authoritative assistant turn", async () => {
		const executions: unknown[] = [];
		const { messages, provider } = await run([makeReadTool(executions)], [
			{ text: READ_MARKUP_PATH2, recovery: READ_RECOVERY },
			{ toolCall: { name: "read", arguments: { path: "E:/KI/ninfer-custom/README.md" } } },
			{ text: "Read the README." },
		]);

		// No assistant message anywhere in the run carries the rejected markup.
		expect(assistantTexts(messages)).not.toContain(READ_MARKUP_PATH2);
		// The live provider context never contains it either: the retry replays
		// without the rejected turn, and the final turn carries only the valid
		// call and its result.
		for (const providerMessages of provider.providerContexts) {
			expect(providerMessages.some(m => JSON.stringify(m).includes("path2"))).toBe(false);
		}
	});
});
