/**
 * @file gapi_waveform.c
 * @brief Test waveform API messages
 * @copyright Copyright (C) 2026 Southern California Edison
 */
#include "gapi_discovery.h"
#include "pb.h"
#include "pb_decode.h"
#include "pb_encode.h"
#include "schemas/waveform.pb.h"

volatile bool running = true;
volatile bool isConnected = false;
volatile bool rr_disconnect = false;
const int TIMEOUT_S = 5;

/**
 * @brief Context structure for the waveform test, used to store
 * information about the device under test and the test result.
 */
struct waveform_test_ctx {
	int test_result;
	int streams_count;
	int stream_index;
	GeisaPlatformDiscovery_Waveform_Instance *streams;
};

/**
 * @brief Callback function to get the discovery information of the device under
 * test. This function decodes the discovery response and updates the context
 * with information about the device.
 *
 * @param mosq The mosquitto client instance
 * @param obj The user data object, which is a pointer to the waveform test
 * context
 * @param msg The MQTT message containing the discovery response
 */
static void get_discovery_information(struct mosquitto *mosq, void *obj,
				      const struct mosquitto_message *msg)
{
	GeisaPlatformDiscovery_Rsp response =
	    GeisaPlatformDiscovery_Rsp_init_default;
	struct waveform_test_ctx *ctx = obj;
	pb_istream_t istream;
	bool status = false;
	(void)mosq;

	ctx->streams_count = 0;
	ctx->streams = NULL;

	istream = pb_istream_from_buffer(msg->payload, msg->payloadlen);
	status =
	    pb_decode(&istream, GeisaPlatformDiscovery_Rsp_fields, &response);

	if (!status) {
		fprintf(stderr,
			"[Waveform] Error decoding discovery response\n");
		ctx->test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (!response.has_waveform) {
		goto disconnect;
	}

	ctx->streams_count = response.waveform.streams_count;
	ctx->streams = calloc(ctx->streams_count, sizeof(*ctx->streams));
	if (!ctx->streams) {
		fprintf(stderr,
			"[Waveform] Error allocating memory for streams\n");
		ctx->test_result = EXIT_FAILURE;
		goto disconnect;
	}

	// Shallow copy as no pointer members are present in the stream
	// structure
	for (int i = 0; i < ctx->streams_count; i++) {
		ctx->streams[i] = response.waveform.streams[i];
	}

disconnect:
	pb_release(GeisaPlatformDiscovery_Rsp_fields, &response);
	rr_disconnect = true;
}

/**
 * @brief Subscribes to waveform streams and checks for successful subscription
 * messages. Sends a subscribe request for each stream in the context, and then
 * sends an unsubscribe request for each stream.
 *
 * @param mosq The mosquitto client instance
 * @param ctx The waveform test context containing information about the streams
 * @param request The waveform request message to send
 * @return EXIT_SUCCESS if all requests were sent successfully, EXIT_FAILURE
 * otherwise
 *
 * @todo Implement the actual subscription and unsubscription logic and checks.
 */
static int subscribe_unsubscribe_waveform_test(struct mosquitto *mosq,
					       struct waveform_test_ctx *ctx,
					       GeisaWaveform_Req *request)
{
	int return_code = EXIT_SUCCESS;
	(void)request;
	(void)mosq;
	(void)ctx;

	return return_code;
}

/**
 * @brief Main function for waveform API tests, initializes MQTT communication,
 * sets appropriate message callback based on command line argument, sends
 * discovery request and waveform request to check waveform response message
 *
 * @param argc Argument count from command line
 * @param argv Argument vector from command line, expects one argument
 * specifying the callback type to test
 * @return EXIT_SUCCESS if all tests pass, EXIT_FAILURE if any test fails or if
 * there is an error in setup
 */
int main(int argc, char *argv[])
{
	GeisaWaveform_Req request = GeisaWaveform_Req_init_default;
	struct mosquitto *mosq = NULL;
	int return_code = 0;
	time_t start = 0;

	if (argc != 2) {
		fprintf(stderr, "Usage: %s <waveform_test_type>\n", argv[0]);
		fprintf(stderr, "waveform test available:\n"
				"* subscribe_unsubscribe\n");
		return EXIT_FAILURE;
	}

	struct waveform_test_ctx *ctx =
	    calloc(1, sizeof(struct waveform_test_ctx));
	if (!ctx) {
		fprintf(stderr,
			"Error allocating memory for waveform test context\n");
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
			fprintf(
			    stderr,
			    "[Waveform] Connection timed out after %d seconds\n",
			    TIMEOUT_S);
			return_code = EXIT_FAILURE;
			goto disconnect;
		}
	}

	if (!isConnected) {
		fprintf(stderr, "[Waveform] Failed to connect to broker\n");
		return_code = EXIT_FAILURE;
		goto disconnect;
	}

	mosquitto_message_callback_set(mosq, get_discovery_information);
	return_code = send_discovery_request(mosq);
	if (return_code != EXIT_SUCCESS) {
		fprintf(stderr, "[Waveform] Error sending discovery request\n");
		goto disconnect;
	}

	// Set running back to true after sending the discovery request as
	// mosquitto publish callback set running to false after sending the
	// message
	running = true;

	if (strcmp(argv[1], "subscribe_unsubscribe") == 0) {
		return_code =
		    subscribe_unsubscribe_waveform_test(mosq, ctx, &request);
	} else {
		fprintf(stderr, "Invalid waveform test type: %s\n", argv[1]);
		return_code = EXIT_FAILURE;
		goto disconnect;
	}

disconnect:
	api_communication_deinit(mosq);
exit:
	return_code = return_code ? return_code : ctx->test_result;
	free(ctx->streams);
	free(ctx);
	return return_code;
}
