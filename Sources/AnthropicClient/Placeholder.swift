// AnthropicClient — minimal URLSession client for POST /v1/messages.
// No official Anthropic Swift SDK exists, so this is raw HTTPS. Knows nothing
// about golf; reusable anywhere.
//
//   headers: x-api-key, anthropic-version: 2023-06-01, content-type: application/json
//   structured output: "output_config": {"format": {"type":"json_schema","schema":{…}}}
//
// Per-model config must be a struct, not an if — the Phase 3 sweep exercises all
// three on day one:
//   claude-haiku-4-5  thinking {type:"enabled", budget_tokens:N}; effort ERRORS
//   claude-sonnet-5   thinking {type:"adaptive"};                 effort supported
//   claude-opus-5     thinking {type:"adaptive"};                 effort supported
//
// Reconstruction output runs ~14.4K tokens — near the non-streaming ceiling, so
// stream it. Keep a /v1/messages/batches path for model sweeps at 50% cost.
// API key from environment or Keychain. Never committed.
//
// TODO(phase-3): MessagesRequest/Response, ModelConfig, streaming, batches.

import Foundation
