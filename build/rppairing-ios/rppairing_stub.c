#include "app/Madeira/MadeiraRPPairing.h"
#include <stdlib.h>

struct MadeiraRPPairing { int dummy; };

MadeiraRPPairing *madeira_rppairing_new(const char *name, char **error) {
    if (error) *error = NULL;
    return NULL;
}

uint16_t madeira_rppairing_port(const MadeiraRPPairing *session) { return 0; }
const char *madeira_rppairing_service_name(const MadeiraRPPairing *session) { return ""; }
size_t madeira_rppairing_txt_count(const MadeiraRPPairing *session) { return 0; }
const char *madeira_rppairing_txt_key(const MadeiraRPPairing *session, size_t index) { return ""; }
const char *madeira_rppairing_txt_value(const MadeiraRPPairing *session, size_t index) { return ""; }

int32_t madeira_rppairing_accept(const MadeiraRPPairing *session,
                                 MadeiraRPPairingPinCallback pin_callback, void *pin_context,
                                 uint8_t **out_plist, size_t *out_len,
                                 char **out_device_name, char **error) {
    if (error) *error = NULL;
    return 1;
}

void madeira_rppairing_cancel(const MadeiraRPPairing *session) {}
void madeira_rppairing_free(MadeiraRPPairing *session) {}
void madeira_rppairing_bytes_free(uint8_t *bytes, size_t len) { if (bytes) free(bytes); }
void madeira_rppairing_string_free(char *string) { if (string) free(string); }
