/**
 * @file gapi_instantaneous.c
 * @brief Test instantaneous API messages
 * @copyright Copyright (C) 2026 Southern California Edison
 */
#include "gapi_mosquitto.h"
#include "pb.h"
#include "pb_decode.h"
#include "pb_encode.h"
#include "schemas/metered_quantities.pb.h"

volatile bool running = true;
volatile bool isConnected = false;
volatile bool rr_disconnect = false;
const int TIMEOUT_S = 5;

static void check_instantaneous_message(struct mosquitto *mosq, void *obj,
					const struct mosquitto_message *msg)
{
	GeisaInstantaneousQuantities response =
	    GeisaInstantaneousQuantities_init_default;
	(void)mosq;
	int *test_result = obj;
	pb_istream_t istream;
	bool status = false;

	*test_result = EXIT_SUCCESS;

	istream = pb_istream_from_buffer(msg->payload, msg->payloadlen);
	status =
	    pb_decode(&istream, GeisaInstantaneousQuantities_fields, &response);

	if (!status) {
		fprintf(
		    stderr,
		    "[Instantaneous] Error decoding instantaneous response\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response.has_phase_A == false) {
		fprintf(stderr, "[Instantaneous] Error: instantaneous response "
				"missing phase_A message\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response.has_phase_B == false) {
		fprintf(stderr, "[Instantaneous] Error: instantaneous response "
				"missing phase_B message\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response.has_phase_C == false) {
		fprintf(stderr, "[Instantaneous] Error: instantaneous response "
				"missing phase_C message\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response.has_phase_N == false) {
		fprintf(stderr, "[Instantaneous] Error: instantaneous response "
				"missing phase_N message\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}
	if (response.has_other == false) {
		fprintf(stderr, "[Instantaneous] Error: instantaneous response "
				"missing other message\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

disconnect:
	pb_release(GeisaInstantaneousQuantities_fields, &response);
	printf("[Instantaneous] test_result: %d\n", *test_result);
	running = false;
}

int main()
{
	struct mosquitto *mosq = NULL;
	int return_code = 0;
	int test_result = 0;
	time_t start = 0;

	mosq = api_communication_init();
	if (!mosq) {
		return_code = EXIT_FAILURE;
		goto exit;
	}

	mosquitto_message_callback_set(mosq, check_instantaneous_message);

	mosquitto_user_data_set(mosq, &test_result);

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

	return_code = api_subscribe(mosq, "geisa/api/instantaneous/data", 0);
	if (return_code != MOSQ_ERR_SUCCESS) {
		fprintf(stderr, "[Discovery] Error subscribing to "
				"geisa/api/instantaneous/data topic\n");
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
	return return_code || test_result;
}
