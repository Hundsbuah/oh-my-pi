import { describe, expect, it, vi } from "bun:test";
import { streamOpenAIResponses } from "@oh-my-pi/pi-ai/providers/openai-responses";
import { extractNInferToolCallRecovery } from "@oh-my-pi/pi-ai/providers/openai-shared";
import type { AssistantMessage, FetchImpl, Model, ProviderSessionState } from "@oh-my-pi/pi-ai/types";
import { getBundledModel } from "@oh-my-pi/pi-catalog/models";

// Stateful chaining is scoped to the NInfer provider, so the test model must
// carry it for both the recovery extension and the chain-baseline behavior.
const model = { ...getBundledModel("openai", "gpt-5-mini"), provider: "ninfer" } as Model<"openai-responses">;
const systemPrompt = ["You are a helpful assistant."];

const RECOVERY = {
	retry_eligible: true,
	fallback_reason: "ambiguous_structure",
	ambiguity_cause: "undeclared_parameter",
	tool_name: "read",
	parameter_names: ["path2"],
	parameter_count: 1,
	parameter_names_truncated: false,
};

/** Text-only Responses SSE stream; optionally carries the ninfer extension on the terminal body. */
function recoverySse(markup: string, responseId: string, ninfer?: Record<string, unknown>): Response {
	const events = [
		{ type: "response.created", response: { id: responseId } },
		{
			type: "response.output_item.added",
			item: { type: "message", id: `msg_${responseId}`, role: "assistant", status: "in_progress", content: [] },
		},
		{ type: "response.content_part.added", part: { type: "output_text", text: "" } },
		{ type: "response.output_text.delta", delta: markup },
		{
			type: "response.output_item.done",
			item: {
				type: "message",
				id: `msg_${responseId}`,
				role: "assistant",
				status: "completed",
				content: [{ type: "output_text", text: markup }],
			},
		},
		{
			type: "response.completed",
			response: {
				id: responseId,
				status: "completed",
				usage: { input_tokens: 5, output_tokens: 3, total_tokens: 8, input_tokens_details: { cached_tokens: 0 } },
				...(ninfer ? { ninfer } : {}),
			},
		},
	];
	return new Response(`${events.map(event => `data: ${JSON.stringify(event)}`).join("\n\n")}\n\n`, {
		status: 200,
		headers: { "content-type": "text/event-stream" },
	});
}

describe("NInfer tool-call recovery extension (R17-02A)", () => {
	const options = (sessionId: string, fetchMock: FetchImpl, providerSessionState?: Map<string, ProviderSessionState>) => ({
		apiKey: "test-key",
		sessionId,
		providerSessionState,
		reasoning: "low" as const,
		fetch: fetchMock,
	});

	it("surfaces the terminal diagnostic verbatim with normal fields intact", async () => {
		const markup =
			"<tool_call><function=read><parameter=path>E:/x.ts</parameter><parameter=path2>5-20</parameter></function></tool_call>";
		const fetchMock = vi.fn(async () => recoverySse(markup, "resp_rej", { tool_call_recovery: RECOVERY })) as FetchImpl;
		const user = { role: "user" as const, content: "read the file", timestamp: 1000 };
		const message = await streamOpenAIResponses(model, { systemPrompt, messages: [user] }, options("r17-a", fetchMock)).result();

		expect(message.stopReason).toBe("stop");
		expect(message.content).toHaveLength(1);
		expect(message.content[0]).toEqual(
			expect.objectContaining({ type: "text", text: markup }),
		);
		expect(message.responseId).toBe("resp_rej");
		expect(message.ninferToolCallRecovery).toEqual(RECOVERY);
	});

	it("leaves the field absent when the terminal body has no extension", async () => {
		const fetchMock = vi.fn(async () => recoverySse("plain answer", "resp_clean")) as FetchImpl;
		const user = { role: "user" as const, content: "hello", timestamp: 1000 };
		const message = await streamOpenAIResponses(model, { systemPrompt, messages: [user] }, options("r17-b", fetchMock)).result();
		expect(message.stopReason).toBe("stop");
		expect(message.ninferToolCallRecovery).toBeUndefined();
	});

	it("keeps the field absent on non-NInfer providers", async () => {
		const openaiModel = { ...model, provider: "openai" } as Model<"openai-responses">;
		const fetchMock = vi.fn(async () => recoverySse("markup", "resp_x", { tool_call_recovery: RECOVERY })) as FetchImpl;
		const user = { role: "user" as const, content: "hello", timestamp: 1000 };
		const message = await streamOpenAIResponses(openaiModel, { systemPrompt, messages: [user] }, options("r17-c", fetchMock)).result();
		// The provider only reads the namespaced extension from the terminal body; the
		// field itself is set verbatim (the agent loop additionally gates on provider === "ninfer").
		expect(message.ninferToolCallRecovery).toEqual(RECOVERY);
	});

	it("drops malformed or oversized extension payloads defensively", () => {
		const valid = { ninfer: { tool_call_recovery: RECOVERY } };
		expect(extractNInferToolCallRecovery(valid)).toEqual(RECOVERY);
		expect(extractNInferToolCallRecovery(undefined)).toBeUndefined();
		expect(extractNInferToolCallRecovery(null)).toBeUndefined();
		expect(extractNInferToolCallRecovery({})).toBeUndefined();
		expect(extractNInferToolCallRecovery({ ninfer: {} })).toBeUndefined();
		expect(extractNInferToolCallRecovery({ ninfer: { tool_call_recovery: null } })).toBeUndefined();

		const broken = (patch: Record<string, unknown>) => ({
			ninfer: { tool_call_recovery: { ...RECOVERY, ...patch } },
		});
		expect(extractNInferToolCallRecovery(broken({ retry_eligible: "yes" }))).toBeUndefined();
		expect(extractNInferToolCallRecovery(broken({ fallback_reason: "" }))).toBeUndefined();
		expect(extractNInferToolCallRecovery(broken({ ambiguity_cause: 7 }))).toBeUndefined();
		expect(extractNInferToolCallRecovery(broken({ tool_name: [] }))).toBeUndefined();
		expect(extractNInferToolCallRecovery(broken({ parameter_names: "path2" }))).toBeUndefined();
		expect(extractNInferToolCallRecovery(broken({ parameter_count: NaN }))).toBeUndefined();
		expect(extractNInferToolCallRecovery(broken({ parameter_names_truncated: "no" }))).toBeUndefined();
	});

	it("re-applies the 8-name and 128-byte bounds defensively", () => {
		const longName = "p".repeat(200);
		const names = ["a", "b", "c", "d", "e", "f", "g", longName, "i", "j"];
		const got = extractNInferToolCallRecovery({
			ninfer: {
				tool_call_recovery: {
					...RECOVERY,
					parameter_names: names,
					parameter_count: 10,
					parameter_names_truncated: false,
				},
			},
		});
		expect(got).toBeDefined();
		expect(got!.parameter_names).toHaveLength(8);
		expect(got!.parameter_names[7]).toHaveLength(128);
		expect(got!.parameter_names_truncated).toBe(true);
		expect(got!.parameter_count).toBe(10);
	});
});

describe("stateful chain baseline after a rejected tool-call turn (R17-02D)", () => {
	const markup =
		"<tool_call><function=read><parameter=path>E:/x.ts</parameter><parameter=path2>5-20</parameter></function></tool_call>";

	it("rejects the response id, then chains from the regenerated successful turn", async () => {
		const sentRequests: Array<Record<string, unknown>> = [];
		const fetchMock = vi.fn(async (_input: string | URL | Request, init?: RequestInit) => {
			sentRequests.push(JSON.parse(String(init?.body)) as Record<string, unknown>);
			switch (sentRequests.length) {
				case 1:
					// The rejected turn: NInfer returns the raw markup as text with the diagnostic.
					return recoverySse(markup, "resp_rej", { tool_call_recovery: RECOVERY });
				case 2:
					// The agent-loop retry (rejected turn discarded from the context).
					return recoverySse("<tool_call><function=read><parameter=path>E:/x.ts</parameter></function></tool_call>", "resp_retry");
				case 3:
					// A subsequent turn after the tool result.
					return recoverySse("done", "resp_next");
				default:
					throw new Error("unexpected request");
			}
		}) as FetchImpl;
		const providerSessionState = new Map<string, ProviderSessionState>();
		const options = {
			apiKey: "test-key",
			sessionId: "r17-stateful",
			providerSessionState,
			statefulResponses: true,
			reasoning: "low" as const,
			fetch: fetchMock,
		};
		const user = { role: "user" as const, content: "read the file", timestamp: 1000 };

		// Turn 1: rejected. The wire response succeeds (status completed), so the
		// provider would normally install it as the chain baseline.
		const rejected = await streamOpenAIResponses(model, { systemPrompt, messages: [user] }, options).result();
		expect(rejected.ninferToolCallRecovery).toEqual(RECOVERY);

		// Turn 2 (the retry): the rejected response must NOT be the previous_response_id
		// baseline — the full history replays instead.
		const retry = await streamOpenAIResponses(
			model,
			{
				systemPrompt,
				// The agent loop discarded the rejected turn; the context carries only the
				// original user message plus the correction context (filtered by the loop).
				messages: [user, { role: "user", content: "regenerate", timestamp: 1001 }],
			},
			options,
		).result();
		expect(retry.ninferToolCallRecovery).toBeUndefined();

		// Turn 3 (after the regenerated turn succeeded): the chain installs from the
		// successful regenerated response.
		await streamOpenAIResponses(
			model,
			{
				systemPrompt,
				messages: [
					user,
					{ role: "user", content: "regenerate", timestamp: 1001 },
					retry,
					{ role: "user", content: "continue", timestamp: 1002 },
				],
			},
			options,
		).result();

		expect(sentRequests).toHaveLength(3);
		expect(sentRequests[0]?.previous_response_id).toBeUndefined();
		expect(sentRequests[1]?.previous_response_id).toBeUndefined();
		expect(JSON.stringify(sentRequests[1]?.input)).toContain("read the file");
		expect(sentRequests[2]?.previous_response_id).toBe("resp_retry");
	});
});
