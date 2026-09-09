#include "GHRCallerAuthentication.h"
#include <pthread.h>

static xpc_peer_requirement_t requirement = NULL;
static pthread_once_t once = PTHREAD_ONCE_INIT;

static void initializeRequirement(void) {
    // The factory returns a retained, concurrency-safe native object. This C cache owns
    // that creation reference until process exit. No per-call release, reset or mutation.
    // NULL is error_out, not a Team ID override: Apple checks this process's actual team.
    requirement = xpc_peer_requirement_create_team_identity(GHRGuesthouseSigningIdentifier, NULL);
}

bool GHRMessageSenderIsGuesthouse(xpc_object_t message) {
    if (message == NULL || xpc_get_type(message) != XPC_TYPE_DICTIONARY) {
        return false;
    }
    // pthread_once publishes the immutable requirement before every read. Initialization
    // or matching failure always refuses; neither raw native errors nor input gets logged.
    if (pthread_once(&once, initializeRequirement) != 0 || requirement == NULL) {
        return false;
    }
    return xpc_peer_requirement_match_received_message(requirement, message, NULL);
}
