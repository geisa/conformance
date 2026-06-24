/**
 * @file gapi_waveform.c
 * @brief Test waveform API messages
 * @copyright Copyright (C) 2026 Southern California Edison
 */
#include "gapi_discovery.h"
#include "geisa_status.h"
#include "pb.h"
#include "pb_decode.h"
#include "pb_encode.h"
#include "schemas/waveform.pb.h"
#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>

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
 * @brief Converts a GeisaWaveform_Datatype to a GeisaWaveform_SampleType.
 *
 * @param sample_type The GeisaWaveform_Datatype to convert
 * @return The corresponding GeisaWaveform_SampleType
 */
static GeisaWaveform_SampleType
get_sample_type(GeisaWaveform_Datatype sample_type)
{
	switch (sample_type) {
	case GeisaWaveform_Datatype_DATA_INT16:
		return GeisaWaveform_SampleType_WAVEFORM_SAMPLE_TYPE_INT16;
	case GeisaWaveform_Datatype_DATA_INT32:
		return GeisaWaveform_SampleType_WAVEFORM_SAMPLE_TYPE_INT32;
	case GeisaWaveform_Datatype_DATA_FLOAT32:
		return GeisaWaveform_SampleType_WAVEFORM_SAMPLE_TYPE_FLOAT32;
	case GeisaWaveform_Datatype_DATA_FLOAT64:
		return GeisaWaveform_SampleType_WAVEFORM_SAMPLE_TYPE_FLOAT64;
	default:
		return GeisaWaveform_SampleType_WAVEFORM_SAMPLE_TYPE_UNSPECIFIED;
	}
}

/**
 * @brief Tests connecting to the socket path provided in the waveform response.
 *
 * @param socket_path The socket path to connect to
 * @return EXIT_SUCCESS if the connection was successful, EXIT_FAILURE otherwise
 */
static int test_connecting_to_socket_path(const char *socket_path)
{
	int file_descriptor = -1;
	struct sockaddr_un addr;

	if (!socket_path || !socket_path[0]) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response missing socket_path information\n");
		return EXIT_FAILURE;
	}

	memset(&addr, 0, sizeof(addr));
	file_descriptor = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_NONBLOCK, 0);
	if (file_descriptor < 0) {
		fprintf(
		    stderr,
		    "[Waveform] Error: cannot create socket for socket_path: %s, errno: %d\n",
		    socket_path, errno);
		return EXIT_FAILURE;
	}
	addr.sun_family = AF_UNIX;

	if (strlen(socket_path) >= sizeof(addr.sun_path)) {
		fprintf(stderr, "[Waveform] Error: socket_path too long: %s\n",
			socket_path);
		close(file_descriptor);
		return EXIT_FAILURE;
	}

	strncpy(addr.sun_path, socket_path, sizeof(addr.sun_path) - 1);
	if (connect(file_descriptor, (struct sockaddr *)&addr, sizeof(addr)) <
	    0) {
		fprintf(
		    stderr,
		    "[Waveform] Error: cannot connect to socket_path: %s, errno: %d\n",
		    socket_path, errno);
		close(file_descriptor);
		return EXIT_FAILURE;
	}
	close(file_descriptor);
	return EXIT_SUCCESS;
}

/**
 * @brief Callback for waveform subscribe message, checks for successful
 * subscribe response and validates the response information against the
 * discovery information.
 *
 * @param mosq mosquitto instance pointer
 * @param obj The user data object, which is a pointer to the waveform test
 * context
 * @param msg pointer to mosquitto message containing waveform response
 */
static void
check_waveform_subscribe_success_message(struct mosquitto *mosq, void *obj,
					 const struct mosquitto_message *msg)
{
	GeisaWaveform_Rsp response = GeisaWaveform_Rsp_init_default;
	(void)mosq;
	struct waveform_test_ctx *ctx = obj;
	int test_result = EXIT_SUCCESS;
	pb_istream_t istream;
	bool status = false;

	istream = pb_istream_from_buffer(msg->payload, msg->payloadlen);
	status = pb_decode(&istream, GeisaWaveform_Rsp_fields, &response);

	if (!status) {
		fprintf(stderr,
			"[Waveform] Error decoding waveform response\n");
		test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response.has_status == false) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response missing status message\n");
		test_result = EXIT_FAILURE;
	}

	if (check_geisa_status(&response.status, "Waveform") != EXIT_SUCCESS) {
		test_result = EXIT_FAILURE;
	}

	if (response.waveform_status != GeisaWaveform_Status_WAVEFORM_SUCCESS) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response waveform_status not successful\n");
		test_result = EXIT_FAILURE;
	}

	if (response.stream_id == NULL ||
	    strcmp(response.stream_id,
		   ctx->streams[ctx->stream_index].stream_id) != 0) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response stream_id does not match request stream_id\n");
		test_result = EXIT_FAILURE;
	}

	if (!response.subscribed) {
		fprintf(stderr,
			"[Waveform] Error: waveform response not subscribed\n");
		test_result = EXIT_FAILURE;
	}

	if (test_connecting_to_socket_path(response.socket_path)) {
		test_result = EXIT_FAILURE;
	}

	if (response.sample_type !=
	    get_sample_type(ctx->streams[ctx->stream_index].datatype)) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response sample_type does not match discovery datatype\n");
		test_result = EXIT_FAILURE;
	}

	if (response.voltage_channel_count !=
	    ctx->streams[ctx->stream_index].num_voltage_ch) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response voltage_channel_count does not match discovery num_voltage_ch\n");
		test_result = EXIT_FAILURE;
	}

	if (response.current_channel_count !=
	    ctx->streams[ctx->stream_index].num_current_ch) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response current_channel_count does not match discovery num_current_ch\n");
		test_result = EXIT_FAILURE;
	}

	if (response.total_channel_count !=
	    ctx->streams[ctx->stream_index].total_channel_count) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response total_channel_count does not match discovery total_channel_count\n");
		test_result = EXIT_FAILURE;
	}

	if (response.sample_rate_hz !=
	    (uint32_t)ctx->streams[ctx->stream_index].sample_rate) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response sample_rate_hz does not match discovery sample_rate\n");
		test_result = EXIT_FAILURE;
	}

	if (response.samples_per_cycle !=
	    ctx->streams[ctx->stream_index].samples_per_cycle) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response samples_per_cycle does not match discovery samples_per_cycle\n");
		test_result = EXIT_FAILURE;
	}

	if (response.nominal_frequency_hz !=
	    ctx->streams[ctx->stream_index].nominal_frequency_hz) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response nominal_frequency_hz does not match discovery nominal_frequency_hz\n");
		test_result = EXIT_FAILURE;
	}

	if (response.cycle_aligned !=
	    ctx->streams[ctx->stream_index].cycle_aligned) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response cycle_aligned does not match discovery cycle_aligned\n");
		test_result = EXIT_FAILURE;
	}

	if (response.zero_crossing_aligned !=
	    ctx->streams[ctx->stream_index].zero_crossing_aligned) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response zero_crossing_aligned does not match discovery zero_crossing_aligned\n");
		test_result = EXIT_FAILURE;
	}

	if (response.voltage_scale !=
	    ctx->streams[ctx->stream_index].voltage_multiplier) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response voltage_scale does not match discovery voltage_multiplier\n");
		test_result = EXIT_FAILURE;
	}

	if (response.current_scale !=
	    ctx->streams[ctx->stream_index].current_multiplier) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response current_scale does not match discovery current_multiplier\n");
		test_result = EXIT_FAILURE;
	}

	if (response.expected_frame_period_ms !=
	    ctx->streams[ctx->stream_index].expected_frame_period_ms) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response expected_frame_period_ms does not match discovery expected_frame_period_ms\n");
		test_result = EXIT_FAILURE;
	}

disconnect:
	pb_release(GeisaWaveform_Rsp_fields, &response);
	fprintf(stdout, "[Waveform] waveform subscribe test_result: %d\n",
		test_result);
	if (test_result == EXIT_FAILURE) {
		ctx->test_result = test_result;
	}
	rr_disconnect = true;
}

/**
 * @brief Callback for waveform unsubscribe message, checks for successful
 * unsubscribe response.
 *
 * @param mosq mosquitto instance pointer
 * @param obj The user data object, which is a pointer to the waveform test
 * context
 * @param msg pointer to mosquitto message containing waveform response
 */
static void
check_waveform_unsubscribe_success_message(struct mosquitto *mosq, void *obj,
					   const struct mosquitto_message *msg)
{
	GeisaWaveform_Rsp response = GeisaWaveform_Rsp_init_default;
	(void)mosq;
	struct waveform_test_ctx *ctx = obj;
	int test_result = EXIT_SUCCESS;
	pb_istream_t istream;
	bool status = false;

	istream = pb_istream_from_buffer(msg->payload, msg->payloadlen);
	status = pb_decode(&istream, GeisaWaveform_Rsp_fields, &response);

	if (!status) {
		fprintf(stderr,
			"[Waveform] Error decoding waveform response\n");
		test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response.has_status == false) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response missing status message\n");
		test_result = EXIT_FAILURE;
	}

	if (check_geisa_status(&response.status, "Waveform") != EXIT_SUCCESS) {
		test_result = EXIT_FAILURE;
	}

	if (response.waveform_status != GeisaWaveform_Status_WAVEFORM_SUCCESS) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response waveform_status not successful\n");
		test_result = EXIT_FAILURE;
	}

	if (response.stream_id == NULL ||
	    strcmp(response.stream_id,
		   ctx->streams[ctx->stream_index].stream_id) != 0) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response stream_id does not match request stream_id\n");
		test_result = EXIT_FAILURE;
	}

	if (response.subscribed) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response not unsubscribed\n");
		test_result = EXIT_FAILURE;
	}

disconnect:
	pb_release(GeisaWaveform_Rsp_fields, &response);
	fprintf(stdout, "[Waveform] waveform unsubscribe test_result: %d\n",
		test_result);
	if (test_result == EXIT_FAILURE) {
		ctx->test_result = test_result;
	}
	rr_disconnect = true;
}

/**
 * @brief Callback for waveform subscribe message when already subscribed,
 * checks for already subscribed response.
 *
 * @param mosq mosquitto instance pointer
 * @param obj The user data object, which is a pointer to the waveform test
 * context
 * @param msg pointer to mosquitto message containing waveform response
 */
static void
check_waveform_already_subscribed_message(struct mosquitto *mosq, void *obj,
					  const struct mosquitto_message *msg)
{
	GeisaWaveform_Rsp response = GeisaWaveform_Rsp_init_default;
	(void)mosq;
	struct waveform_test_ctx *ctx = obj;
	int test_result = EXIT_SUCCESS;
	pb_istream_t istream;
	bool status = false;

	istream = pb_istream_from_buffer(msg->payload, msg->payloadlen);
	status = pb_decode(&istream, GeisaWaveform_Rsp_fields, &response);

	if (!status) {
		fprintf(stderr,
			"[Waveform] Error decoding waveform response\n");
		test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (check_geisa_status(&response.status, "Waveform") != EXIT_SUCCESS) {
		test_result = EXIT_FAILURE;
	}

	if (response.waveform_status !=
	    GeisaWaveform_Status_WAVEFORM_ERR_ALREADY_SUBSCRIBED) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response waveform_status should be already subscribed\n");
		test_result = EXIT_FAILURE;
	}

disconnect:
	pb_release(GeisaWaveform_Rsp_fields, &response);
	fprintf(stdout,
		"[Waveform] waveform already subscribed test_result: %d\n",
		test_result);
	if (test_result == EXIT_FAILURE) {
		ctx->test_result = test_result;
	}
	rr_disconnect = true;
}

/**
 * @brief Callback for waveform unsubscribe message when not subscribed,
 * checks for not subscribed response.
 *
 * @param mosq mosquitto instance pointer
 * @param obj The user data object, which is a pointer to the waveform test
 * context
 * @param msg pointer to mosquitto message containing waveform response
 */
static void
check_waveform_not_subscribed_message(struct mosquitto *mosq, void *obj,
				      const struct mosquitto_message *msg)
{
	GeisaWaveform_Rsp response = GeisaWaveform_Rsp_init_default;
	(void)mosq;
	struct waveform_test_ctx *ctx = obj;
	int test_result = EXIT_SUCCESS;
	pb_istream_t istream;
	bool status = false;

	istream = pb_istream_from_buffer(msg->payload, msg->payloadlen);
	status = pb_decode(&istream, GeisaWaveform_Rsp_fields, &response);

	if (!status) {
		fprintf(stderr,
			"[Waveform] Error decoding waveform response\n");
		test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response.has_status == false) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response missing status message\n");
		test_result = EXIT_FAILURE;
	}

	if (check_geisa_status(&response.status, "Waveform") != EXIT_SUCCESS) {
		test_result = EXIT_FAILURE;
	}

	if (response.waveform_status !=
	    GeisaWaveform_Status_WAVEFORM_ERR_NOT_SUBSCRIBED) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response waveform_status should be not subscribed\n");
		test_result = EXIT_FAILURE;
	}

disconnect:
	pb_release(GeisaWaveform_Rsp_fields, &response);
	fprintf(stdout, "[Waveform] waveform not subscribed test_result: %d\n",
		test_result);
	if (test_result == EXIT_FAILURE) {
		ctx->test_result = test_result;
	}
	rr_disconnect = true;
}

/**
 * @brief Callback for waveform subscribe message when invalid stream_id,
 * checks for invalid stream_id response.
 *
 * @param mosq mosquitto instance pointer
 * @param obj The user data object, which is a pointer to the waveform test
 * context
 * @param msg pointer to mosquitto message containing waveform response
 */
static void
check_waveform_invalid_stream_id_message(struct mosquitto *mosq, void *obj,
					 const struct mosquitto_message *msg)
{
	GeisaWaveform_Rsp response = GeisaWaveform_Rsp_init_default;
	(void)mosq;
	struct waveform_test_ctx *ctx = obj;
	int test_result = EXIT_SUCCESS;
	pb_istream_t istream;
	bool status = false;

	istream = pb_istream_from_buffer(msg->payload, msg->payloadlen);
	status = pb_decode(&istream, GeisaWaveform_Rsp_fields, &response);

	if (!status) {
		fprintf(stderr,
			"[Waveform] Error decoding waveform response\n");
		test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response.has_status == false) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response missing status message\n");
		test_result = EXIT_FAILURE;
	}

	if (check_geisa_status(&response.status, "Waveform") != EXIT_SUCCESS) {
		test_result = EXIT_FAILURE;
	}

	if (response.waveform_status !=
	    GeisaWaveform_Status_WAVEFORM_ERR_INVALID_STREAM_ID) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response waveform_status should be invalid stream_id\n");
		test_result = EXIT_FAILURE;
	}

disconnect:
	pb_release(GeisaWaveform_Rsp_fields, &response);
	fprintf(stdout,
		"[Waveform] waveform invalid stream_id test_result: %d\n",
		test_result);
	if (test_result == EXIT_FAILURE) {
		ctx->test_result = test_result;
	}
	rr_disconnect = true;
}

/**
 * @brief Callback for waveform subscribe message when unavailable stream_id,
 * checks for unavailable stream_id response.
 *
 * @param mosq mosquitto instance pointer
 * @param obj The user data object, which is a pointer to the waveform test
 * context
 * @param msg pointer to mosquitto message containing waveform response
 */
static void check_waveform_unavailable_stream_id_message(
    struct mosquitto *mosq, void *obj, const struct mosquitto_message *msg)
{
	GeisaWaveform_Rsp response = GeisaWaveform_Rsp_init_default;
	(void)mosq;
	struct waveform_test_ctx *ctx = obj;
	int test_result = EXIT_SUCCESS;
	pb_istream_t istream;
	bool status = false;

	istream = pb_istream_from_buffer(msg->payload, msg->payloadlen);
	status = pb_decode(&istream, GeisaWaveform_Rsp_fields, &response);

	if (!status) {
		fprintf(stderr,
			"[Waveform] Error decoding waveform response\n");
		test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response.has_status == false) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response missing status message\n");
		test_result = EXIT_FAILURE;
	}

	if (check_geisa_status(&response.status, "Waveform") != EXIT_SUCCESS) {
		test_result = EXIT_FAILURE;
	}

	if (response.waveform_status !=
	    GeisaWaveform_Status_WAVEFORM_ERR_UNAVAILABLE) {
		fprintf(
		    stderr,
		    "[Waveform] Error: waveform response waveform_status should be unavailable stream_id\n");
		test_result = EXIT_FAILURE;
	}

disconnect:
	pb_release(GeisaWaveform_Rsp_fields, &response);
	fprintf(stdout,
		"[Waveform] waveform unavailable stream_id test_result: %d\n",
		test_result);
	if (test_result == EXIT_FAILURE) {
		ctx->test_result = test_result;
	}
	rr_disconnect = true;
}

/**
 * @brief Sends a waveform request message to the device under test.
 *
 * @param mosq The mosquitto client instance
 * @param request The waveform request message to send
 * @return EXIT_SUCCESS if the request was sent successfully, EXIT_FAILURE
 * otherwise
 */
static int send_waveform_request(struct mosquitto *mosq,
				 GeisaWaveform_Req *request)
{
	uint8_t *message = NULL;
	size_t encoded_size = 0;
	pb_ostream_t ostream;
	bool status = false;
	int return_code = 0;

	status = pb_get_encoded_size(&encoded_size, GeisaWaveform_Req_fields,
				     request);
	if (!status) {
		fprintf(
		    stderr,
		    "[Waveform] Error calculating encoded size for waveform request\n");
		return EXIT_FAILURE;
	}

	message = malloc(encoded_size);
	if (message == NULL) {
		fprintf(
		    stderr,
		    "[Waveform] Error allocating memory for waveform request\n");
		return EXIT_FAILURE;
	}
	ostream = pb_ostream_from_buffer(message, encoded_size);
	status = pb_encode(&ostream, GeisaWaveform_Req_fields, request);
	if (!status) {
		fprintf(stderr, "[Waveform] Error encoding waveform request\n");
		free(message);
		return EXIT_FAILURE;
	}
	return_code = api_request_response(
	    mosq, "geisa/api/waveform/req/gapi-conformance-tests", encoded_size,
	    message, "geisa/api/waveform/rsp/gapi-conformance-tests", 1);

	free(message);
	return return_code;
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
 */
static int subscribe_unsubscribe_waveform_test(struct mosquitto *mosq,
					       struct waveform_test_ctx *ctx,
					       GeisaWaveform_Req *request)
{
	int return_code = EXIT_SUCCESS;
	ctx->test_result = EXIT_SUCCESS;

	for (ctx->stream_index = 0; ctx->stream_index < ctx->streams_count;
	     ctx->stream_index++) {
		fprintf(stdout, "[Waveform] Subscribing to stream_id: %s\n",
			ctx->streams[ctx->stream_index].stream_id);
		mosquitto_message_callback_set(
		    mosq, check_waveform_subscribe_success_message);
		request->stream_id = ctx->streams[ctx->stream_index].stream_id;
		request->request_type =
		    GeisaWaveform_RequestType_WAVEFORM_SUBSCRIBE;

		if (send_waveform_request(mosq, request) != EXIT_SUCCESS) {
			fprintf(
			    stderr,
			    "[Waveform] Error sending waveform subscribe request for stream_id: %s\n",
			    ctx->streams[ctx->stream_index].stream_id);
			return_code = EXIT_FAILURE;
		}
		mosquitto_message_callback_set(
		    mosq, check_waveform_unsubscribe_success_message);
		request->stream_id = ctx->streams[ctx->stream_index].stream_id;
		request->request_type =
		    GeisaWaveform_RequestType_WAVEFORM_UNSUBSCRIBE;
		if (send_waveform_request(mosq, request) != EXIT_SUCCESS) {
			fprintf(
			    stderr,
			    "[Waveform] Error sending waveform unsubscribe request for stream_id: %s\n",
			    ctx->streams[ctx->stream_index].stream_id);
			return_code = EXIT_FAILURE;
		}
	}

	return return_code;
}

/**
 * @brief Subscribes two times to waveform streams and checks for already
 * subscribed messages.
 *
 * @param mosq The mosquitto client instance
 * @param ctx The waveform test context containing information about the streams
 * @param request The waveform request message to send
 * @return EXIT_SUCCESS if all requests were sent successfully, EXIT_FAILURE
 * otherwise
 */
static int already_subscribed_waveform_test(struct mosquitto *mosq,
					    struct waveform_test_ctx *ctx,
					    GeisaWaveform_Req *request)
{
	int return_code = EXIT_SUCCESS;
	ctx->test_result = EXIT_SUCCESS;

	for (ctx->stream_index = 0; ctx->stream_index < ctx->streams_count;
	     ctx->stream_index++) {
		fprintf(stdout, "[Waveform] Subscribing to stream_id: %s\n",
			ctx->streams[ctx->stream_index].stream_id);
		mosquitto_message_callback_set(
		    mosq, check_waveform_subscribe_success_message);
		request->stream_id = ctx->streams[ctx->stream_index].stream_id;
		request->request_type =
		    GeisaWaveform_RequestType_WAVEFORM_SUBSCRIBE;
		if (send_waveform_request(mosq, request) == EXIT_FAILURE) {
			fprintf(
			    stderr,
			    "[Waveform] Error sending waveform subscribe request for stream_id: %s\n",
			    ctx->streams[ctx->stream_index].stream_id);
			return_code = EXIT_FAILURE;
		}

		mosquitto_message_callback_set(
		    mosq, check_waveform_already_subscribed_message);
		request->stream_id = ctx->streams[ctx->stream_index].stream_id;
		request->request_type =
		    GeisaWaveform_RequestType_WAVEFORM_SUBSCRIBE;
		if (send_waveform_request(mosq, request) != EXIT_SUCCESS) {
			fprintf(
			    stderr,
			    "[Waveform] Error sending waveform subscribe request for stream_id: %s\n",
			    ctx->streams[ctx->stream_index].stream_id);
			return_code = EXIT_FAILURE;
		}

		/* Unsubscribe from the stream to clean up for the next test */
		mosquitto_message_callback_set(
		    mosq, check_waveform_unsubscribe_success_message);
		request->stream_id = ctx->streams[ctx->stream_index].stream_id;
		request->request_type =
		    GeisaWaveform_RequestType_WAVEFORM_UNSUBSCRIBE;
		if (send_waveform_request(mosq, request) != EXIT_SUCCESS) {
			fprintf(
			    stderr,
			    "[Waveform] Error sending waveform unsubscribe request for stream_id: %s\n",
			    ctx->streams[ctx->stream_index].stream_id);
			return_code = EXIT_FAILURE;
		}
	}

	return return_code;
}

/**
 * @brief Unsubscribes from waveform streams and checks for not subscribed
 * messages.
 *
 * @param mosq The mosquitto client instance
 * @param ctx The waveform test context containing information about the streams
 * @param request The waveform request message to send
 * @return EXIT_SUCCESS if all requests were sent successfully, EXIT_FAILURE
 * otherwise
 */
static int not_subscribed_waveform_test(struct mosquitto *mosq,
					struct waveform_test_ctx *ctx,
					GeisaWaveform_Req *request)
{
	int return_code = EXIT_SUCCESS;
	ctx->test_result = EXIT_SUCCESS;

	for (ctx->stream_index = 0; ctx->stream_index < ctx->streams_count;
	     ctx->stream_index++) {
		fprintf(stdout, "[Waveform] Unsubscribing from stream_id: %s\n",
			ctx->streams[ctx->stream_index].stream_id);
		mosquitto_message_callback_set(
		    mosq, check_waveform_not_subscribed_message);
		request->stream_id = ctx->streams[ctx->stream_index].stream_id;
		request->request_type =
		    GeisaWaveform_RequestType_WAVEFORM_UNSUBSCRIBE;
		if (send_waveform_request(mosq, request) != EXIT_SUCCESS) {
			fprintf(
			    stderr,
			    "[Waveform] Error sending waveform unsubscribe request for stream_id: %s\n",
			    ctx->streams[ctx->stream_index].stream_id);
			return_code = EXIT_FAILURE;
		}
	}

	return return_code;
}

/**
 * @brief Unsubscribes from an invalid stream_id and checks for invalid
 * stream_id error message.
 *
 * @param mosq The mosquitto client instance
 * @param ctx The waveform test context containing information about the streams
 * @param request The waveform request message to send
 * @return EXIT_SUCCESS if all requests were sent successfully, EXIT_FAILURE
 * otherwise
 */
static int invalid_stream_id_waveform_test(struct mosquitto *mosq,
					   struct waveform_test_ctx *ctx,
					   GeisaWaveform_Req *request)
{
	int return_code = EXIT_SUCCESS;
	ctx->test_result = EXIT_SUCCESS;

	mosquitto_message_callback_set(
	    mosq, check_waveform_invalid_stream_id_message);
	request->stream_id = NULL;
	request->request_type = GeisaWaveform_RequestType_WAVEFORM_UNSUBSCRIBE;
	if (send_waveform_request(mosq, request) != EXIT_SUCCESS) {
		fprintf(
		    stderr,
		    "[Waveform] Error sending waveform unsubscribe request for invalid stream_id\n");
		return_code = EXIT_FAILURE;
	}

	return return_code;
}

/**
 * @brief Unsubscribes from an unavailable stream_id and checks for unavailable
 * error message.
 *
 * @param mosq The mosquitto client instance
 * @param ctx The waveform test context containing information about the streams
 * @param request The waveform request message to send
 * @return EXIT_SUCCESS if all requests were sent successfully, EXIT_FAILURE
 * otherwise
 */
static int unavailable_stream_id_waveform_test(struct mosquitto *mosq,
					       struct waveform_test_ctx *ctx,
					       GeisaWaveform_Req *request)
{
	int return_code = EXIT_SUCCESS;
	ctx->test_result = EXIT_SUCCESS;

	mosquitto_message_callback_set(
	    mosq, check_waveform_unavailable_stream_id_message);
	request->stream_id = "unavailable_stream_id";
	request->request_type = GeisaWaveform_RequestType_WAVEFORM_UNSUBSCRIBE;
	if (send_waveform_request(mosq, request) != EXIT_SUCCESS) {
		fprintf(
		    stderr,
		    "[Waveform] Error sending waveform unsubscribe request for unavailable stream_id\n");
		return_code = EXIT_FAILURE;
	}

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
				"* subscribe_unsubscribe\n"
				"* already_subscribed\n"
				"* not_subscribed\n"
				"* invalid_stream_id\n"
				"* unavailable_stream_id\n");
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
	} else if (strcmp(argv[1], "already_subscribed") == 0) {
		return_code =
		    already_subscribed_waveform_test(mosq, ctx, &request);
	} else if (strcmp(argv[1], "not_subscribed") == 0) {
		return_code = not_subscribed_waveform_test(mosq, ctx, &request);
	} else if (strcmp(argv[1], "invalid_stream_id") == 0) {
		return_code =
		    invalid_stream_id_waveform_test(mosq, ctx, &request);
	} else if (strcmp(argv[1], "unavailable_stream_id") == 0) {
		return_code =
		    unavailable_stream_id_waveform_test(mosq, ctx, &request);
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
