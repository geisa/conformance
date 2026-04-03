/**
 * @file gapi_discovery.c
 * @brief Test discovery API messages
 * @copyright Copyright (C) 2026 Southern California Edison
 */
#include "gapi_mosquitto.h"
#include "schemas/discovery.pb-c.h"

volatile bool running = true;
volatile bool isConnected = false;
volatile bool rr_disconnect = false;

static void check_discovery_message(struct mosquitto *mosq, void *obj,
				    const struct mosquitto_message *msg)
{
	GeisaPlatformDiscoveryRsp *response = NULL;
	(void)mosq;
	(void)obj;

	rr_disconnect = true;

	response = geisa_platform_discovery__rsp__unpack(
	    NULL, msg->payloadlen, (uint8_t *)msg->payload);

	if (response == NULL) {
		fprintf(stderr, "[Discovery] Error unpacking platform "
				"discovery response\n");
		return;
	}

	geisa_platform_discovery__rsp__free_unpacked(response, NULL);
}

int main()
{
	GeisaPlatformDiscoveryReq request = GEISA_PLATFORM_DISCOVERY__REQ__INIT;
	struct mosquitto *mosq = NULL;
	uint8_t *message = NULL;
	int return_code = 0;

	mosq = api_communication_init();
	if (!mosq) {
		return_code = EXIT_FAILURE;
		goto exit;
	}

	mosquitto_message_callback_set(mosq, check_discovery_message);

	while (running && !isConnected) {
		mosquitto_loop(mosq, -1, 1);
		sleep(1);
	}

	if (!isConnected) {
		fprintf(stderr, "Failed to connect to broker\n");
		return_code = EXIT_FAILURE;
		goto disconnect;
	}

	message =
	    malloc(geisa_platform_discovery__req__get_packed_size(&request));
	if (message == NULL) {
		fprintf(stderr, "[Discovery] Error allocating memory for "
				"platform discovery request\n");
		return_code = EXIT_FAILURE;
		goto disconnect;
	}
	geisa_platform_discovery__req__pack(&request, message);
	return_code = api_request_response(
	    mosq, "geisa/api/platform/discovery/req/gapi-conformance-tests",
	    geisa_platform_discovery__req__get_packed_size(&request), message,
	    "geisa/api/platform/discovery/rsp/gapi-conformance-tests", 1);

	free(message);

disconnect:
	api_communication_deinit(mosq);
exit:
	return return_code;
}
