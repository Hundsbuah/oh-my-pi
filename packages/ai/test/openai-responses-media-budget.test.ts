import { describe, expect, it } from "bun:test";
import * as AIError from "@oh-my-pi/pi-ai/error";
import { streamOpenAIResponses } from "@oh-my-pi/pi-ai/providers/openai-responses";
import type { FetchImpl, Model } from "@oh-my-pi/pi-ai/types";
import { getBundledModel } from "@oh-my-pi/pi-catalog/models";

const model = { ...getBundledModel("openai", "gpt-5-mini"), provider: "ninfer" } as Model<"openai-responses">;

describe("openai-responses NInfer media budget rejection", () => {
	it("surfaces a 400 media_budget_exceeded as a non-retried payload rejection that names the code", async () => {
		let calls = 0;
		const fetchMock = (async () => {
			calls++;
			return new Response(
				JSON.stringify({
					error: {
						message: "vision tokens exceed processor budget",
						type: "invalid_request_error",
						param: "input",
						code: "media_budget_exceeded",
					},
				}),
				{ status: 400, headers: { "content-type": "application/json" } },
			);
		}) as FetchImpl;

		const result = await streamOpenAIResponses(
			model,
			{
				systemPrompt: ["You are a helpful assistant."],
				messages: [{ role: "user", content: "Describe", timestamp: 1 }],
			},
			{ apiKey: "test-key", fetch: fetchMock },
		).result();

		expect(calls).toBe(1);
		expect(result.stopReason).toBe("error");
		expect(result.errorStatus).toBe(400);
		// Session maintenance keys its media-budget dead end on this code in the message.
		expect(result.errorMessage).toContain("media_budget_exceeded");
		expect(AIError.isPayloadRejection(result)).toBe(true);
		expect(AIError.isContextOverflow(result)).toBe(false);
	});
});
