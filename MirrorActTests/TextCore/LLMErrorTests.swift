// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// What the failures of the language model services mean (Foundation only: also runs on Linux).
/// Bodies marked "as received" are what the services answered to a made-up key in November 2026
/// (line breaks added); the others follow the services' documentation.
final class LLMErrorTests: XCTestCase {
    private func error(_ status: Int, _ body: String, headers: [LLMHeader] = []) -> LLMError {
        LLMError.from(status: status, headers: headers, body: Data(body.utf8))
    }

    // MARK: The key

    func testWrongKeyAsReceived() {
        // OpenAI, 401
        let openAI = #"""
            {
                "error": {
                    "message": "Incorrect API key provided: invalid-****************heck. \#
            You can find your API key at https://platform.openai.com/account/api-keys.",
                    "type": "invalid_request_error",
                    "param": null,
                    "code": "invalid_api_key"
                }
            }
            """#
        XCTAssertEqual(error(401, openAI), .invalidKey)
        XCTAssertEqual(LLMError.message(in: Data(openAI.utf8)), "Incorrect API key provided: invalid-****************heck. "
                       + "You can find your API key at https://platform.openai.com/account/api-keys.")
        // Anthropic, 401
        XCTAssertEqual(error(401, #"""
            {"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"},
             "request_id":"req_011CgwBYy4H5ivTBJKW2jM7T"}
            """#), .invalidKey)
        // Mistral, 401: the text is in "detail"
        XCTAssertEqual(error(401, #"{"detail":"Invalid API Key"}"#), .invalidKey)
        // DeepSeek, 401
        XCTAssertEqual(error(401, #"""
            {"error":{"message":"Authentication Fails, Your api key: ****heck is invalid \#
            (request_id: 7a5ee903-7239-45f5-8c65-8fe40fe9e519)",
             "type":"authentication_error","param":null,"code":"invalid_request_error"}}
            """#), .invalidKey)
        // Groq, 401
        XCTAssertEqual(error(401, #"{"error":{"message":"Invalid API Key","type":"invalid_request_error","code":"invalid_api_key"}}"#),
                       .invalidKey)
        // OpenRouter, 401: the code is a number
        XCTAssertEqual(error(401, #"{"error":{"message":"User not found.","code":401}}"#), .invalidKey)
        // Ollama's cloud, 401
        XCTAssertEqual(error(401, #"{"error":{"message":"Unauthorized","type":"api_error","param":null,"code":null}}"#), .invalidKey)
    }

    func testWrongKeyThatArrivesAsABadRequest() {
        // Gemini's OpenAI endpoint, 400, as received: the error object is inside a list
        XCTAssertEqual(error(400, #"""
            [{
              "error": {
                "code": 400,
                "message": "Please pass a valid API key",
                "status": "INVALID_ARGUMENT"
              }
            }
            ]
            """#), .invalidKey)
        // Gemini, 400, as received from its own API
        XCTAssertEqual(error(400, #"""
            {
              "error": {
                "code": 400,
                "message": "API key not valid. Please pass a valid API key.",
                "status": "INVALID_ARGUMENT",
                "details": [
                  {
                    "@type": "type.googleapis.com/google.rpc.ErrorInfo",
                    "reason": "API_KEY_INVALID",
                    "domain": "googleapis.com",
                    "metadata": {
                      "service": "generativelanguage.googleapis.com"
                    }
                  }
                ]
              }
            }
            """#), .invalidKey)
        // xAI, 400, as received: "error" is a string
        XCTAssertEqual(error(400, #"""
            {"code":"invalid-argument",
             "error":"Incorrect API key provided. You can obtain an API key from https://console.x.ai."}
            """#), .invalidKey)
        // the reason alone is enough
        XCTAssertEqual(error(400, #"{"error":{"code":400,"message":"Bad request","details":[{"reason":"API_KEY_INVALID"}]}}"#),
                       .invalidKey)
    }

    // MARK: Rights, models, money

    func testNoAccess() {
        XCTAssertEqual(error(403, #"""
            {"type":"error","request_id":"req_1","error":{"type":"permission_error",
             "message":"Your API key does not have permission to use the specified resource."}}
            """#), .noAccess)
        XCTAssertEqual(error(403, #"{"error":{"code":403,"message":"The caller does not have permission","status":"PERMISSION_DENIED"}}"#),
                       .noAccess)
        // OpenAI: the project may not use the model
        XCTAssertEqual(error(403, #"""
            {"error":{"message":"Project `proj_1` does not have access to model `gpt-6.1-sol`",
             "type":"invalid_request_error","param":null,"code":"model_not_found"}}
            """#), .noAccess)
        XCTAssertEqual(error(403, "<html><head><title>403 Forbidden</title></head><body>…</body></html>"), .noAccess)
        XCTAssertEqual(error(403, ""), .noAccess)
    }

    func testUnknownModel() {
        XCTAssertEqual(error(404, #"""
            {"error":{"message":"The model `gpt-9` does not exist or you do not have access to it.",
             "type":"invalid_request_error","param":null,"code":"model_not_found"}}
            """#), .unknownModel)
        XCTAssertEqual(error(404, #"{"type":"error","error":{"type":"not_found_error","message":"model: claude-nope-1"},"request_id":"req_1"}"#),
                       .unknownModel)
        // Ollama: the model was not pulled
        XCTAssertEqual(error(404, #"""
            {"error":{"message":"model \"llama9\" not found, try pulling it first","type":"not_found_error","param":null,"code":null}}
            """#), .unknownModel)
        XCTAssertEqual(error(404, #"{"error":"model 'llama9' not found"}"#), .unknownModel)
        // Azure: no deployment of that name
        XCTAssertEqual(error(404, #"{"error":{"code":"DeploymentNotFound","message":"The API deployment for this resource does not exist."}}"#),
                       .unknownModel)
        XCTAssertEqual(error(404, #"""
            {"error":{"code":404,"message":"models/gemini-9 is not found for API version v1beta","status":"NOT_FOUND"}}
            """#), .unknownModel)
        XCTAssertEqual(error(404, #"""
            {"error":{"code":404,"message":"No endpoints found for acme/none.","metadata":{"error_type":"not_found"}}}
            """#), .unknownModel)
        // some services answer 400
        XCTAssertEqual(error(400, #"""
            {"object":"error","message":"Invalid model: mistral-nope","type":"invalid_model","param":null,"code":"1500"}
            """#), .unknownModel)
        XCTAssertEqual(error(400, #"""
            {"error":{"message":"Model Not Exist","type":"invalid_request_error","param":null,"code":"invalid_request_error"}}
            """#), .unknownModel)
        XCTAssertEqual(error(400, #"{"error":{"message":"acme/none is not a valid model ID","code":400}}"#), .unknownModel)
    }

    func testAWrongAddressIsNoUnknownModel() {
        XCTAssertEqual(error(404, #"{"detail":"Not Found"}"#), .server(status: 404, message: "Not Found"))
        XCTAssertEqual(error(404, "404 page not found\n"), .server(status: 404, message: "404 page not found"))
        XCTAssertEqual(error(404, "<!DOCTYPE html>\n<html>\n<head><title>404 Not Found</title></head>\n<body><h1>Not Found</h1></body></html>"),
                       .server(status: 404, message: "404 Not Found"))
        XCTAssertEqual(error(404, #"{"error":{"code":"404","message":"Resource not found"}}"#),
                       .server(status: 404, message: "Resource not found"))
        XCTAssertEqual(error(405, ""), .server(status: 405, message: ""))
    }

    func testOutOfCredit() {
        // DeepSeek and OpenRouter: 402
        XCTAssertEqual(error(402, #"""
            {"error":{"message":"Insufficient Balance","type":"unknown_error","param":null,"code":"invalid_request_error"}}
            """#), .outOfCredit)
        XCTAssertEqual(error(402, #"{"error":{"code":402,"message":"Insufficient credits","metadata":{"error_type":"payment_required"}}}"#),
                       .outOfCredit)
        XCTAssertEqual(error(402, #"{"type":"error","error":{"type":"billing_error","message":"Your credit balance is too low."}}"#),
                       .outOfCredit)
        // OpenAI reports these as 429; waiting does not help
        for code in ["credit_balance_exhausted", "organization_spend_limit_exceeded", "project_spend_limit_exceeded",
                     "organization_usage_limit_exceeded", "insufficient_quota"] {
            let body = #"{"error":{"message":"You exceeded your current quota.","type":"insufficient_quota","param":null,"code":"\#(code)"}}"#
            XCTAssertEqual(error(429, body, headers: [LLMHeader("Retry-After", "5")]), .outOfCredit, code)
        }
        XCTAssertEqual(error(429, #"{"error":{"message":"No credits.","type":"invalid_request_error","code":"credit_balance_exhausted"}}"#),
                       .outOfCredit)
        // Anthropic: the monthly limit of the usage tier, as documented
        XCTAssertEqual(error(429, #"""
            {
              "type": "error",
              "error": {
                "type": "rate_limit_error",
                "message": "You have reached your API usage limits: your organization has crossed its monthly API usage \#
            threshold, set based on your organization's API tier. You will regain access on 2026-09-01 at 00:00 UTC.",
                "details": { "error_code": "enforced_spend_limit_reached" }
              },
              "request_id": "req_018EeWyXxfu5pfWkrYcMdjWG"
            }
            """#), .outOfCredit)
        // Anthropic: a limit the user has set arrives as a bad request
        XCTAssertEqual(error(400, #"""
            {"type":"error","request_id":"req_1","error":{"type":"invalid_request_error",
             "message":"You have reached your specified API usage limits. You will regain access on 2026-12-01 at 00:00 UTC."}}
            """#), .outOfCredit)
        XCTAssertEqual(error(400, #"""
            {"type":"error","error":{"type":"invalid_request_error",
             "message":"You have reached your specified workspace API usage limits. You will regain access on 2026-12-01 at 00:00 UTC."}}
            """#), .outOfCredit)
        // OpenRouter: a budget of the key or the workspace is spent, as documented
        XCTAssertEqual(error(403, #"""
            {"error":{"code":403,
             "message":"Budget limit exceeded (weekly limit). Contact your org admin. $52.00 of $50.00 used; resets 2026-10-12T00:00:00.000Z.",
             "metadata":{"limit_source":"openrouter_guardrail_budget","scope":"workspace_default_member","limit_usd":50,"spend_usd":52,
                         "resets_at":"2026-10-12T00:00:00.000Z"}}}
            """#), .outOfCredit)
        XCTAssertEqual(error(403, #"{"error":{"code":403,"message":"Key limit exceeded","metadata":{"limit_source":"openrouter_key_limit"}}}"#),
                       .outOfCredit)
    }

    func testABudgetThatIsOnlyUsedUpForTheMomentIsARateLimit() {
        // OpenRouter: 402 with the time to wait
        let body = #"{"error":{"code":402,"message":"In-flight budget exhausted","metadata":{"limit_source":"openrouter_in_flight_budget"}}}"#
        XCTAssertEqual(error(402, body, headers: [LLMHeader("Retry-After", "30")]), .rateLimited(retryAfterSeconds: 30))
        XCTAssertEqual(error(402, body), .outOfCredit)
    }

    // MARK: Waiting helps

    func testRateLimitsAndTheTimeToWait() {
        let openAI = #"{"error":{"message":"Rate limit reached for requests","type":"requests","param":null,"code":"rate_limit_exceeded"}}"#
        XCTAssertEqual(error(429, openAI), .rateLimited(retryAfterSeconds: nil))
        XCTAssertEqual(error(429, openAI, headers: [LLMHeader("Retry-After", "7")]), .rateLimited(retryAfterSeconds: 7))
        XCTAssertEqual(error(429, openAI, headers: [LLMHeader("retry-after", " 2.5 ")]), .rateLimited(retryAfterSeconds: 2.5))
        // Azure names milliseconds; they are the more exact value
        XCTAssertEqual(error(429, openAI, headers: [LLMHeader("retry-after", "2"), LLMHeader("retry-after-ms", "1500")]),
                       .rateLimited(retryAfterSeconds: 1.5))
        XCTAssertEqual(error(429, openAI, headers: [LLMHeader("Retry-After-Ms", "250")]), .rateLimited(retryAfterSeconds: 0.25))
        // a date, nonsense, a negative number: no time
        for value in ["Wed, 11 Nov 2026 12:00:00 GMT", "soon", "-3", "", "1e3", "0x10", "nan", "inf", "1.2.3", "99999999999999999999"] {
            XCTAssertEqual(error(429, openAI, headers: [LLMHeader("Retry-After", value)]), .rateLimited(retryAfterSeconds: nil), value)
        }
        let anthropic = #"{"type":"error","error":{"type":"rate_limit_error","message":"This request would exceed your rate limit."}}"#
        XCTAssertEqual(error(429, anthropic, headers: [LLMHeader("retry-after", "12")]), .rateLimited(retryAfterSeconds: 12))
        XCTAssertEqual(error(429, #"""
            {"error":{"code":429,"message":"Resource has been exhausted (e.g. check quota).","status":"RESOURCE_EXHAUSTED"}}
            """#), .rateLimited(retryAfterSeconds: nil))
        XCTAssertEqual(error(429, ""), .rateLimited(retryAfterSeconds: nil))
    }

    func testOverload() {
        XCTAssertEqual(error(529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"},"request_id":"req_1"}"#),
                       .overloaded)
        XCTAssertEqual(error(503, #"""
            {"error":{"message":"The model is temporarily overloaded.","type":"service_unavailable_error","code":"server_is_overloaded"}}
            """#), .overloaded)
        XCTAssertEqual(error(503, #"""
            {"error":{"code":503,"message":"The model is overloaded. Please try again later.","status":"UNAVAILABLE"}}
            """#), .overloaded)
        XCTAssertEqual(error(503, ""), .overloaded)
        // Groq's own status: no capacity in the flex tier
        XCTAssertEqual(error(498, #"{"error":{"message":"Flex tier capacity exceeded","type":"invalid_request_error"}}"#), .overloaded)
        // Anthropic can report an overload with another status
        XCTAssertEqual(error(500, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#), .overloaded)
    }

    func testServerErrors() {
        XCTAssertEqual(error(500, #"{"type":"error","error":{"type":"api_error","message":"Internal server error"},"request_id":"req_1"}"#),
                       .server(status: 500, message: "Internal server error"))
        XCTAssertEqual(error(504, #"{"type":"error","error":{"type":"timeout_error","message":"Request timed out"}}"#),
                       .server(status: 504, message: "Request timed out"))
        // the page of a gateway instead of JSON
        let page = "<html>\r\n<head><title>502 Bad Gateway</title></head>\r\n<body>\r\n<center><h1>502 Bad Gateway</h1></center>\r\n"
            + "<hr><center>cloudflare</center>\r\n</body>\r\n</html>\r\n"
        XCTAssertEqual(error(502, page), .server(status: 502, message: "502 Bad Gateway"))
        XCTAssertEqual(error(502, "<html><body>no title</body></html>"), .server(status: 502, message: ""))
        XCTAssertEqual(error(500, "upstream connect error or disconnect/reset before headers"),
                       .server(status: 500, message: "upstream connect error or disconnect/reset before headers"))
        XCTAssertEqual(error(500, ""), .server(status: 500, message: ""))
        XCTAssertEqual(error(500, #""just a string""#), .server(status: 500, message: "just a string"))
        XCTAssertEqual(error(408, #"{"error":{"code":408,"message":"Your request timed out"}}"#),
                       .server(status: 408, message: "Your request timed out"))
    }

    // MARK: The request or the text was the problem

    func testRejectedRequests() {
        // Mistral, 422: the field and what is wrong with it
        XCTAssertEqual(error(422, #"""
            {"detail":[{"type":"enum","loc":["body","reasoning_effort"],"msg":"Input should be 'high' or 'none'","input":"low"}]}
            """#), .badRequest("reasoning_effort: Input should be 'high' or 'none'"))
        XCTAssertEqual(error(422, #"""
            {"detail":[{"type":"extra_forbidden","loc":["body","max_completion_tokens"],"msg":"Extra inputs are not permitted"}]}
            """#), .badRequest("max_completion_tokens: Extra inputs are not permitted"))
        XCTAssertEqual(error(422, #"{"detail":[{"msg":"Field required"}]}"#), .badRequest("Field required"))
        // LM Studio: "error" is a string
        XCTAssertEqual(error(400, #"{"error":"'response_format.type' must be 'json_schema'"}"#),
                       .badRequest("'response_format.type' must be 'json_schema'"))
        // Ollama: a model without thinking was asked to think less
        XCTAssertEqual(error(400, #"""
            {"error":{"message":"\"gemma4:e4b\" does not support thinking","type":"invalid_request_error","param":null,"code":null}}
            """#), .badRequest("\"gemma4:e4b\" does not support thinking"))
        // a field the model does not take: this must stay a bad request, so that it is sent again without the field
        XCTAssertEqual(error(400, #"""
            {"error":{"message":"Unsupported value: 'reasoning_effort' does not support 'low' with this model.",
             "type":"invalid_request_error","param":"reasoning_effort","code":"unsupported_value"}}
            """#), .badRequest("Unsupported value: 'reasoning_effort' does not support 'low' with this model."))
        // Anthropic: the organization may not use a beta
        XCTAssertEqual(error(400, #"""
            {"type":"error","request_id":"req_1","error":{"type":"invalid_request_error",
             "message":"Unexpected value(s) `server-side-fallback-2026-07-01` for the `anthropic-beta` header."}}
            """#), .badRequest("Unexpected value(s) `server-side-fallback-2026-07-01` for the `anthropic-beta` header."))
        XCTAssertEqual(error(400, ""), .badRequest(""))
        XCTAssertEqual(error(400, #"{"error":{"message":"Bad request","type":"invalid_request_error"}}"#), .badRequest("Bad request"))
    }

    func testDeclinedBecauseOfTheText() {
        // Azure: the filter objected to the text that was sent
        XCTAssertEqual(error(400, #"""
            {"error":{"message":"The response was filtered due to the prompt triggering Azure OpenAI's content management policy.",
             "type":null,"param":"prompt","code":"content_filter","status":400,"innererror":{"code":"ResponsibleAIPolicyViolation"}}}
            """#), .refused)
        XCTAssertEqual(error(400, #"{"error":{"message":"Filtered.","inner_error":{"code":"ResponsibleAIPolicyViolation"}}}"#), .refused)
        // OpenRouter: moderation, as documented; this is no fault of the key although the status is 403
        XCTAssertEqual(error(403, #"""
            {"error":{"code":403,"message":"Input flagged",
             "metadata":{"reasons":["violence"],"flagged_input":"…","provider_name":"OpenAI","model_slug":"openai/gpt-6-luna"}}}
            """#), .refused)
        XCTAssertEqual(error(403, #"""
            {"error":{"code":403,"message":"Request blocked: prompt injection patterns detected",
             "metadata":{"patterns":["ignore all previous instructions"]}}}
            """#), .refused)
        XCTAssertEqual(error(403, #"""
            {"error":{"code":403,"message":"Refused","metadata":{"error_type":"refusal","provider_name":"Anthropic"}}}
            """#), .refused)
        XCTAssertEqual(error(403, #"{"error":{"code":403,"message":"Flagged","metadata":{"error_type":"content_policy_violation"}}}"#),
                       .refused)
    }

    func testTooLongForTheModel() {
        XCTAssertEqual(error(400, #"""
            {"error":{"message":"This model's maximum context length is 8192 tokens.","type":"invalid_request_error",
             "param":"messages","code":"context_length_exceeded"}}
            """#), .truncated)
        XCTAssertEqual(error(400, #"{"error":{"code":400,"message":"Output limit reached","metadata":{"error_type":"max_tokens_exceeded"}}}"#),
                       .truncated)
        // too large a request, whatever the service calls it
        XCTAssertEqual(error(413, #"{"type":"error","error":{"type":"request_too_large","message":"Request exceeds the maximum size"}}"#),
                       .truncated)
        XCTAssertEqual(error(413, #"""
            {"error":{"message":"Request too large for model `openai/gpt-oss-120b` on tokens per minute (TPM): Limit 8000, Requested 9131.",
             "type":"tokens","code":"rate_limit_exceeded"}}
            """#), .truncated, "waiting does not make this request smaller")
        XCTAssertEqual(error(413, ""), .truncated)
    }

    // MARK: The message

    func testTheMessageIsOneShortLine() {
        let long = String(repeating: "word ", count: 100)
        guard case .badRequest(let message) = error(400, #"{"error":{"message":"\#(long)"}}"#) else {
            XCTFail("a rejected request")
            return
        }
        XCTAssertEqual(message.count, 200)
        XCTAssertTrue(message.hasSuffix("word word…"), message)

        XCTAssertEqual(error(400, #"{"error":{"message":"  first line\r\n\tsecond   line\u0000 \n"}}"#),
                       .badRequest("first line second line"))
        let exact = String(repeating: "x", count: 200)
        XCTAssertEqual(error(400, #"{"error":{"message":"\#(exact)"}}"#), .badRequest(exact))
    }

    func testTheMessageOfEveryShape() {
        func message(_ body: String) -> String {
            LLMError.message(in: Data(body.utf8))
        }
        XCTAssertEqual(message(#"{"error":{"message":"from an object"}}"#), "from an object")
        XCTAssertEqual(message(#"{"error":"from a string"}"#), "from a string")
        XCTAssertEqual(message(#"{"detail":"from detail"}"#), "from detail")
        XCTAssertEqual(message(#"{"detail":[{"loc":["body",3],"msg":"from a list"}]}"#), "from a list")
        XCTAssertEqual(message(#"[{"error":{"message":"from inside a list"}}]"#), "from inside a list")
        XCTAssertEqual(message(#"{"message":"from the top"}"#), "from the top")
        XCTAssertEqual(message("plain text"), "plain text")
        XCTAssertEqual(message("<HTML><HEAD><TITLE>Gateway Timeout</TITLE></HEAD></HTML>"), "Gateway Timeout")
        XCTAssertEqual(message(""), "")
        XCTAssertEqual(message("{}"), "")
        XCTAssertEqual(message(#"{"error":{"type":"x"}}"#), "")
        XCTAssertEqual(message(#"{"error":null}"#), "")
        XCTAssertEqual(message("[]"), "")
        XCTAssertEqual(message("42"), "", "JSON without words")
    }

    // MARK: What the caller may do

    func testWhichFailuresArePermanentAndWhichAreWorthAnotherTry() {
        let all: [(LLMError, permanent: Bool, retryable: Bool)] = [
            (.invalidKey, true, false),
            (.noAccess, true, false),
            (.unknownModel, true, false),
            (.outOfCredit, true, false),
            (.rateLimited(retryAfterSeconds: nil), false, true),
            (.rateLimited(retryAfterSeconds: 3), false, true),
            (.overloaded, false, true),
            (.badRequest("x"), false, false),
            (.refused, false, false),
            (.truncated, false, false),
            (.server(status: 500, message: ""), false, true),
            (.server(status: 502, message: ""), false, true),
            (.server(status: 408, message: ""), false, true),
            (.server(status: 200, message: ""), false, true),
            (.server(status: 404, message: ""), false, false),
            (.server(status: 405, message: ""), false, false),
            (.malformedReply("x"), false, false),
        ]
        for (error, permanent, retryable) in all {
            XCTAssertEqual(error.isPermanent, permanent, "\(error)")
            XCTAssertEqual(error.isRetryable, retryable, "\(error)")
        }
    }
}
