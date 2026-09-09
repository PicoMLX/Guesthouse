#pragma once
#include <xpc/xpc.h>

// One fixed identity for both listener and per-message requirements. This matches the
// GUI's PRODUCT_BUNDLE_IDENTIFIER; no caller-supplied identity or team is accepted.
#define GHRGuesthouseSigningIdentifier "com.starlingprotocol.Guesthouse"

API_AVAILABLE(macos(26.0))
bool GHRMessageSenderIsGuesthouse(xpc_object_t _Nullable message);
