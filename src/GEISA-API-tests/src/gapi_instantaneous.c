/**
 * @file gapi_instantaneous.c
 * @brief Test instantaneous API messages
 * @copyright Copyright (C) 2026 Southern California Edison
 */

#include "gapi_discovery.h"
#include "gapi_mosquitto.h"
#include "pb.h"
#include "pb_decode.h"
#include "pb_encode.h"
#include "schemas/metered_quantities.pb.h"
#include <stdbool.h>

volatile bool running = true;
volatile bool isConnected = false;
volatile bool rr_disconnect = false;
const int TIMEOUT_S = 5;

/**
 * @brief Context structure for the instantaneous test, used to store
 * information about the device under test and the test result.
 */
struct instantaneous_test_ctx {
	int test_result;
	bool is_meter;
	uint32_t phase_count;
	bool neutral_connected;
};

/**
 * @brief Callback function to get the discovery information of the device under
 * test. This function decodes the discovery response and updates the context
 * with information about the device.
 *
 * @param mosq The mosquitto client instance
 * @param obj The user data object, which is a pointer to the instantaneous test
 * context
 * @param msg The MQTT message containing the discovery response
 */
static void get_discovery_information(struct mosquitto *mosq, void *obj,
				      const struct mosquitto_message *msg)
{
	GeisaPlatformDiscovery_Rsp response =
	    GeisaPlatformDiscovery_Rsp_init_default;
	struct instantaneous_test_ctx *ctx = obj;
	pb_istream_t istream;
	bool status = false;
	(void)mosq;

	ctx->is_meter = false;
	ctx->phase_count = 0;
	ctx->neutral_connected = false;

	istream = pb_istream_from_buffer(msg->payload, msg->payloadlen);
	status =
	    pb_decode(&istream, GeisaPlatformDiscovery_Rsp_fields, &response);

	if (!status) {
		fprintf(stderr,
			"[Instantaneous] Error decoding discovery response\n");
		ctx->test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response.has_metrology == false) {
		goto disconnect;
	}

	if (response.device.top_module.type ==
	    GeisaPlatformDiscovery_DeviceType_TYPE_ELECTRIC_METER) {
		ctx->is_meter = true;
		ctx->phase_count = response.metrology.phase_count;
		ctx->neutral_connected = response.metrology.neutral_connected;
	}

disconnect:
	pb_release(GeisaPlatformDiscovery_Rsp_fields, &response);
	rr_disconnect = true;
}

/**
 * @brief Function to check the instantaneous response for a meter. This
 * function checks that the response contains the expected messages when the
 * device is a meter.
 *
 * @param ctx The context of the instantaneous test, containing information
 * about the device under test
 * @param response The decoded instantaneous response from the meter
 */
static void
check_meter_instantaneous_response(struct instantaneous_test_ctx *ctx,
				   GeisaInstantaneousQuantities *response)
{
	if (ctx->phase_count == 1) {
		if (response->has_phase_A == false) {
			fprintf(
			    stderr,
			    "[Instantaneous] Error: single phase meter instantaneous response missing phase_A message\n");
			ctx->test_result = EXIT_FAILURE;
		}
	} else if (ctx->phase_count == 2) {
		if (response->has_phase_A == false) {
			fprintf(
			    stderr,
			    "[Instantaneous] Error: two phase meter instantaneous response missing phase_A message\n");
			ctx->test_result = EXIT_FAILURE;
		}
		if (response->has_phase_B == false) {
			fprintf(
			    stderr,
			    "[Instantaneous] Error: two phase meter instantaneous response missing phase_B message\n");
			ctx->test_result = EXIT_FAILURE;
		}
	} else if (ctx->phase_count == 3) {
		if (response->has_phase_A == false) {
			fprintf(
			    stderr,
			    "[Instantaneous] Error: three phase meter instantaneous response missing phase_A message\n");
			ctx->test_result = EXIT_FAILURE;
		}
		if (response->has_phase_B == false) {
			fprintf(
			    stderr,
			    "[Instantaneous] Error: three phase meter instantaneous response missing phase_B message\n");
			ctx->test_result = EXIT_FAILURE;
		}
		if (response->has_phase_C == false) {
			fprintf(
			    stderr,
			    "[Instantaneous] Error: three phase meter instantaneous response missing phase_C message\n");
			ctx->test_result = EXIT_FAILURE;
		}
	}
	if (ctx->neutral_connected) {
		if (response->has_phase_N == false) {
			fprintf(
			    stderr,
			    "[Instantaneous] Error: meter with neutral connected instantaneous response missing neutral message\n");
			ctx->test_result = EXIT_FAILURE;
		}
	}
}

/**
 * @brief Callback function to check the instantaneous response message. This
 * function decodes the instantaneous response and checks that it contains the
 * expected information based on the device type and discovery information.
 *
 * @param mosq The mosquitto client instance
 * @param obj The user data object, which is a pointer to the instantaneous test
 * context
 * @param msg The MQTT message containing the instantaneous response
 */
static void check_instantaneous_message(struct mosquitto *mosq, void *obj,
					const struct mosquitto_message *msg)
{
	GeisaInstantaneousQuantities response =
	    GeisaInstantaneousQuantities_init_default;
	(void)mosq;
	struct instantaneous_test_ctx *ctx = obj;
	pb_istream_t istream;
	bool status = false;

	ctx->test_result = EXIT_SUCCESS;

	istream = pb_istream_from_buffer(msg->payload, msg->payloadlen);
	status =
	    pb_decode(&istream, GeisaInstantaneousQuantities_fields, &response);

	if (!status) {
		fprintf(
		    stderr,
		    "[Instantaneous] Error decoding instantaneous response\n");
		ctx->test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response.timestamp == 0) {
		fprintf(
		    stderr,
		    "[Instantaneous] Error: instantaneous response missing timestamp information\n");
		ctx->test_result = EXIT_FAILURE;
	}

	if (ctx->is_meter) {
		check_meter_instantaneous_response(ctx, &response);
	}

	if (response.has_other == false) {
		fprintf(
		    stderr,
		    "[Instantaneous] Error: instantaneous response missing other message\n");
		ctx->test_result = EXIT_FAILURE;
	}

disconnect:
	pb_release(GeisaInstantaneousQuantities_fields, &response);
	fprintf(stdout, "[Instantaneous] test_result: %d\n", ctx->test_result);
	running = false;
}

/**
 * @brief Main function for the instantaneous API test. This function
 * initializes the MQTT communication, sends a discovery request, and checks the
 * instantaneous response messages.
 *
 * @return EXIT_SUCCESS if the test passes, EXIT_FAILURE if the test fails
 */
int main()
{
	struct mosquitto *mosq = NULL;
	int return_code = 0;
	time_t start = 0;

	struct instantaneous_test_ctx *ctx =
	    calloc(1, sizeof(struct instantaneous_test_ctx));
	if (!ctx) {
		fprintf(
		    stderr,
		    "Error allocating memory for instantaneous test context\n");
		return EXIT_FAILURE;
	}

	ctx->test_result = 0;

	mosq = api_communication_init();
	if (!mosq) {
		return_code = EXIT_FAILURE;
		goto exit;
	}

	mosquitto_user_data_set(mosq, ctx);

	start = time(NULL);
	while (running && !isConnected) {
		mosquitto_loop(mosq, -1, 1);
		if (difftime(time(NULL), start) > TIMEOUT_S) {
			fprintf(stderr,
				"Connection timed out after %d seconds\n",
				TIMEOUT_S);
			return_code = EXIT_FAILURE;
			goto disconnect;
		}
	}

	if (!isConnected) {
		fprintf(stderr, "Failed to connect to broker\n");
		return_code = EXIT_FAILURE;
		goto disconnect;
	}

	mosquitto_message_callback_set(mosq, get_discovery_information);
	return_code = send_discovery_request(mosq);
	if (return_code == EXIT_FAILURE) {
		fprintf(stderr,
			"[Instantaneous] Error sending discovery request\n");
		goto disconnect;
	}

	// Set running back to true after sending the discovery request
	running = true;

	mosquitto_message_callback_set(mosq, check_instantaneous_message);

	return_code = api_subscribe(mosq, "geisa/api/instantaneous/data", 0);
	if (return_code != MOSQ_ERR_SUCCESS) {
		fprintf(
		    stderr,
		    "[Instantaneous] Error subscribing to geisa/api/instantaneous/data topic\n");
		return_code = EXIT_FAILURE;
		goto disconnect;
	}

	start = time(NULL);
	while (running) {
		mosquitto_loop(mosq, -1, 1);
		if (difftime(time(NULL), start) > TIMEOUT_S) {
			fprintf(stderr, "Test timed out after %d seconds\n",
				TIMEOUT_S);
			return_code = EXIT_FAILURE;
			goto disconnect;
		}
	}

disconnect:
	api_communication_deinit(mosq);
exit:
	return_code = return_code ? return_code : ctx->test_result;
	free(ctx);
	return return_code;
}
