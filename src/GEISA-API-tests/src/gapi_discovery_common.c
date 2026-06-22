/**
 * @file gapi_discovery_common.c
 * @brief Definitions for common functions for GAPI tests
 * @copyright Copyright (C) 2026 Southern California Edison
 */
#include "gapi_discovery.h"
#include "pb.h"
#include "pb_decode.h"
#include "pb_encode.h"

/**
 * @brief Send a platform discovery request and wait for the response
 *
 * @param mosq The MQTT client instance to use for sending the request
 * @return int EXIT_SUCCESS if the request was sent and the response was
 * received successfully, EXIT_FAILURE if there was an error sending the request
 * or receiving the response
 */
int send_discovery_request(struct mosquitto *mosq)
{
	GeisaPlatformDiscovery_Req request =
	    GeisaPlatformDiscovery_Req_init_default;
	uint8_t *message = NULL;
	size_t encoded_size = 0;
	pb_ostream_t ostream;
	bool status = false;
	int return_code = 0;

	status = pb_get_encoded_size(
	    &encoded_size, GeisaPlatformDiscovery_Req_fields, &request);
	if (!status) {
		fprintf(
		    stderr,
		    "[Discovery] Error calculating encoded size for platform discovery request\n");
		return EXIT_FAILURE;
	}

	message = malloc(encoded_size);
	if (message == NULL) {
		fprintf(
		    stderr,
		    "[Discovery] Error allocating memory for platform discovery request\n");
		return EXIT_FAILURE;
	}
	ostream = pb_ostream_from_buffer(message, encoded_size);
	status =
	    pb_encode(&ostream, GeisaPlatformDiscovery_Req_fields, &request);
	if (!status) {
		fprintf(
		    stderr,
		    "[Discovery] Error encoding platform discovery request\n");
		free(message);
		return EXIT_FAILURE;
	}
	return_code = api_request_response(
	    mosq, "geisa/api/platform/discovery/req/gapi-conformance-tests",
	    encoded_size, message,
	    "geisa/api/platform/discovery/rsp/gapi-conformance-tests", 1);

	free(message);
	pb_release(GeisaPlatformDiscovery_Req_fields, &request);
	return return_code;
}
