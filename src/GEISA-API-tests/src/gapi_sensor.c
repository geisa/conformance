/**
 * @file gapi_sensor.c
 * @brief Test sensor API messages
 * @copyright Copyright (C) 2026 Southern California Edison
 */
#include "gapi_discovery.h"
#include "geisa_status.h"
#include "pb.h"
#include "pb_decode.h"
#include "pb_encode.h"
#include "schemas/sensor.pb.h"
#include <math.h>

volatile bool running = true;
volatile bool isConnected = false;
volatile bool rr_disconnect = false;
const int TIMEOUT_S = 5;

/**
 * @brief Context structure for the sensor test, used to store
 * information about the device under test and the test result.
 */
struct sensor_test_ctx {
	int test_result;
	int sensors_count;
	int sensor_id_requested;
	GeisaSensorDescriptor *sensor;
};

/**
 * @brief Callback function to get the discovery information of the device under
 * test. This function decodes the discovery response and updates the context
 * with information about the device.
 *
 * @param mosq The mosquitto client instance
 * @param obj The user data object, which is a pointer to the sensor test
 * context
 * @param msg The MQTT message containing the discovery response
 */
static void get_discovery_information(struct mosquitto *mosq, void *obj,
				      const struct mosquitto_message *msg)
{
	GeisaPlatformDiscovery_Rsp response =
	    GeisaPlatformDiscovery_Rsp_init_default;
	struct sensor_test_ctx *ctx = obj;
	pb_istream_t istream;
	bool status = false;
	(void)mosq;

	ctx->sensors_count = 0;
	ctx->sensor = NULL;

	istream = pb_istream_from_buffer(msg->payload, msg->payloadlen);
	status =
	    pb_decode(&istream, GeisaPlatformDiscovery_Rsp_fields, &response);

	if (!status) {
		fprintf(stderr, "[Sensor] Error decoding discovery response\n");
		ctx->test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (!response.has_sensor) {
		goto disconnect;
	}

	ctx->sensors_count = response.sensor.sensors_count;
	ctx->sensor = calloc(ctx->sensors_count, sizeof(*ctx->sensor));
	if (!ctx->sensor) {
		fprintf(stderr,
			"[Sensor] Error allocating memory for streams\n");
		ctx->test_result = EXIT_FAILURE;
		goto disconnect;
	}

	// Shallow copy as no pointer members are present in the sensor
	// structure
	for (int i = 0; i < ctx->sensors_count; i++) {
		ctx->sensor[i] = response.sensor.sensors[i];
	}

disconnect:
	pb_release(GeisaPlatformDiscovery_Rsp_fields, &response);
	rr_disconnect = true;
}

/**
 * @brief Function to check the sensor response readings values for each
 * requested sensor. This function checks for valid values in the sensor
 * response readings.
 *
 * @param reading The sensor reading to be checked
 * @param ctx The sensor test context containing information about the device
 * and the test result
 */
static void check_sensor_response_readings_values(GeisaSensorReading *reading,
						  struct sensor_test_ctx *ctx)
{
	for (int i = 0; i < reading->values_count; i++) {
		if (reading->values[i].which_value ==
		    GeisaSensorValue_double_value_tag) {
			if (isnan(reading->values[i].value.double_value)) {
				fprintf(
				    stderr,
				    "[Sensor] Sensor response double value is NaN for %s\n",
				    reading->sensor_id);
				ctx->test_result = EXIT_FAILURE;
			}
		} else if (reading->values[i].which_value ==
			   GeisaSensorValue_int64_value_tag) {
			// No specific check for int64 values
		} else if (reading->values[i].which_value ==
			   GeisaSensorValue_bool_value_tag) {
			// No specific check for bool values
		} else if (reading->values[i].which_value ==
			   GeisaSensorValue_string_value_tag) {
			if (reading->values[i].value.string_value[0] == '\0') {
				fprintf(
				    stderr,
				    "[Sensor] Sensor response string value is empty for %s\n",
				    reading->sensor_id);
				ctx->test_result = EXIT_FAILURE;
			}
		} else {
			fprintf(
			    stderr,
			    "[Sensor] Sensor response has unknown value type for %s\n",
			    reading->sensor_id);
			ctx->test_result = EXIT_FAILURE;
		}
	}
}

/**
 * @brief Function to check the sensor response readings for each requested
 * sensor. This function checks for the presence of required fields and valid
 * values in the sensor response readings.
 *
 * @param response The sensor response message containing the readings
 * @param ctx The sensor test context containing information about the device
 * and the test result
 */
static void check_sensor_response_readings(GeisaSensorReadings_Rsp *response,
					   struct sensor_test_ctx *ctx)
{
	for (int i = 0; i < response->readings_count; i++) {
		fprintf(stderr,
			"[Sensor] Checking sensor response for sensor_id %s\n",
			response->readings[i].sensor_id);
		if (response->readings[i].sensor_id[0] == '\0') {
			fprintf(stderr,
				"[Sensor] Sensor response missing sensor_id\n");
			ctx->test_result = EXIT_FAILURE;
		}
		if (response->readings[i].timestamp_ms == 0) {
			fprintf(stderr,
				"[Sensor] Sensor response missing timestamp\n");
			ctx->test_result = EXIT_FAILURE;
		}
		check_sensor_response_readings_values(&response->readings[i],
						      ctx);
		if (response->readings[i].has_unit) {
			if (response->readings[i].unit[0] == '\0') {
				fprintf(
				    stderr,
				    "[Sensor] Sensor response missing unit\n");
				ctx->test_result = EXIT_FAILURE;
			}
		}
		if (response->readings[i].has_quality) {
			if (response->readings[i].quality[0] == '\0') {
				fprintf(
				    stderr,
				    "[Sensor] Sensor response missing quality\n");
				ctx->test_result = EXIT_FAILURE;
			}
		}
		if (response->readings[i].has_status) {
			if (response->readings[i].status[0] == '\0') {
				fprintf(
				    stderr,
				    "[Sensor] Sensor response missing status\n");
				ctx->test_result = EXIT_FAILURE;
			}
		}
	}
}

/**
 * @brief Callback function to check the sensor response message for each
 * requested sensor. This function decodes the sensor response and checks for
 * the presence of required fields and valid values.
 *
 * @param mosq The mosquitto client instance
 * @param obj The user data object, which is a pointer to the sensor test
 * context
 * @param msg The MQTT message containing the sensor response
 */
static void
check_sensor_request_each_sensor_message(struct mosquitto *mosq, void *obj,
					 const struct mosquitto_message *msg)
{
	GeisaSensorReadings_Rsp response = GeisaSensorReadings_Rsp_init_default;
	struct sensor_test_ctx *ctx = obj;
	pb_istream_t istream;
	bool status = false;
	(void)mosq;

	ctx->test_result = EXIT_SUCCESS;

	istream = pb_istream_from_buffer(msg->payload, msg->payloadlen);
	status = pb_decode(&istream, GeisaSensorReadings_Rsp_fields, &response);

	if (!status) {
		fprintf(stderr, "[Sensor] Error decoding sensor response\n");
		ctx->test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response.has_status == false) {
		fprintf(
		    stderr,
		    "[Sensor] Error: Sensor response missing status message\n");
		ctx->test_result = EXIT_FAILURE;
	}

	if (check_geisa_status(&response.status, "Sensor") != EXIT_SUCCESS) {
		ctx->test_result = EXIT_FAILURE;
	}

	if (response.readings_count != ctx->sensor_id_requested) {
		fprintf(
		    stderr,
		    "[Sensor] Sensor response count does not match requested count\n");
		ctx->test_result = EXIT_FAILURE;
	}

	check_sensor_response_readings(&response, ctx);

disconnect:
	pb_release(GeisaSensorReadings_Rsp_fields, &response);
	fprintf(stdout, "[Sensor] test result: %d\n", ctx->test_result);
	rr_disconnect = true;
}

/**
 * @brief Callback function to check the sensor response message for a sensor
 * that is not present on the device under test. This function decodes the
 * sensor response and checks for the presence of required fields and valid
 * values.
 *
 * @param mosq The mosquitto client instance
 * @param obj The user data object, which is a pointer to the sensor test
 * context
 * @param msg The MQTT message containing the sensor response
 */
static void
check_sensor_not_present_sensor_message(struct mosquitto *mosq, void *obj,
					const struct mosquitto_message *msg)
{
	GeisaSensorReadings_Rsp response = GeisaSensorReadings_Rsp_init_default;
	struct sensor_test_ctx *ctx = obj;
	pb_istream_t istream;
	bool status = false;
	(void)mosq;

	ctx->test_result = EXIT_SUCCESS;

	istream = pb_istream_from_buffer(msg->payload, msg->payloadlen);
	status = pb_decode(&istream, GeisaSensorReadings_Rsp_fields, &response);

	if (!status) {
		fprintf(stderr, "[Sensor] Error decoding sensor response\n");
		ctx->test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response.has_status == false) {
		fprintf(
		    stderr,
		    "[Sensor] Error: Sensor response missing status message\n");
		ctx->test_result = EXIT_FAILURE;
	}

	if (response.status.code !=
	    GeisaStatusCode_GEISA_STATUS_CODE_RESOURCE_NOT_FOUND) {
		fprintf(
		    stderr,
		    "[Sensor] Error: response should have status code resource not found.\n");
		ctx->test_result = EXIT_FAILURE;
	}

	if (!response.status.message || !response.status.message[0]) {
		fprintf(
		    stderr,
		    "[Sensor] Error: response missing status message information\n");
		ctx->test_result = EXIT_FAILURE;
	}

	if (response.readings_count != 0) {
		fprintf(stderr,
			"[Sensor] Error: Sensor response count should be 0\n");
		ctx->test_result = EXIT_FAILURE;
	}

disconnect:
	pb_release(GeisaSensorReadings_Rsp_fields, &response);
	fprintf(stdout, "[Sensor] test result: %d\n", ctx->test_result);
	rr_disconnect = true;
}

/**
 * @brief Callback function to check the sensor response message for a sensor
 * that is not readable from the device under test. This function decodes the
 * sensor response and checks for the presence of required fields and valid
 * values.
 *
 * @param mosq The mosquitto client instance
 * @param obj The user data object, which is a pointer to the sensor test
 * context
 * @param msg The MQTT message containing the sensor response
 */
static void
check_sensor_non_readable_sensor_message(struct mosquitto *mosq, void *obj,
					 const struct mosquitto_message *msg)
{
	GeisaSensorReadings_Rsp response = GeisaSensorReadings_Rsp_init_default;
	struct sensor_test_ctx *ctx = obj;
	pb_istream_t istream;
	bool status = false;
	(void)mosq;

	ctx->test_result = EXIT_SUCCESS;

	istream = pb_istream_from_buffer(msg->payload, msg->payloadlen);
	status = pb_decode(&istream, GeisaSensorReadings_Rsp_fields, &response);

	if (!status) {
		fprintf(stderr, "[Sensor] Error decoding sensor response\n");
		ctx->test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response.has_status == false) {
		fprintf(
		    stderr,
		    "[Sensor] Error: Sensor response missing status message\n");
		ctx->test_result = EXIT_FAILURE;
	}

	if (response.status.code !=
	    GeisaStatusCode_GEISA_STATUS_CODE_EXEC_NOT_SUPPORTED) {
		fprintf(
		    stderr,
		    "[Sensor] Error: response should have status code not supported.\n");
		ctx->test_result = EXIT_FAILURE;
	}

	if (!response.status.message || !response.status.message[0]) {
		fprintf(
		    stderr,
		    "[Sensor] Error: response missing status message information\n");
		ctx->test_result = EXIT_FAILURE;
	}

	if (response.readings_count != 0) {
		fprintf(stderr,
			"[Sensor] Error: Sensor response count should be 0\n");
		ctx->test_result = EXIT_FAILURE;
	}

disconnect:
	pb_release(GeisaSensorReadings_Rsp_fields, &response);
	fprintf(stdout, "[Sensor] test result: %d\n", ctx->test_result);
	rr_disconnect = true;
}

/**
 * @brief Function to send a sensor request message to the device under test
 *
 * @param mosq The mosquitto client instance
 * @param request The sensor readings request message to be sent
 * @return EXIT_SUCCESS if the request was sent successfully, EXIT_FAILURE if
 * there was an error in sending the request or allocating memory for the
 * request
 */
static int send_sensor_request(struct mosquitto *mosq,
			       GeisaSensorReadings_Req *request)
{
	uint8_t *message = NULL;
	size_t encoded_size = 0;
	pb_ostream_t ostream;
	bool status = false;
	int return_code = 0;

	status = pb_get_encoded_size(&encoded_size,
				     GeisaSensorReadings_Req_fields, request);
	if (!status) {
		fprintf(
		    stderr,
		    "[Sensor] Error getting encoded size for sensor request\n");
		return EXIT_FAILURE;
	}
	message = malloc(encoded_size);
	if (message == NULL) {
		fprintf(
		    stderr,
		    "[Sensor] Error allocating memory for sensor request\n");
		return EXIT_FAILURE;
	}
	ostream = pb_ostream_from_buffer(message, encoded_size);
	status = pb_encode(&ostream, GeisaSensorReadings_Req_fields, request);
	if (!status) {
		fprintf(stderr, "[Sensor] Error encoding sensor request\n");
		free(message);
		return EXIT_FAILURE;
	}
	return_code = api_request_response(
	    mosq, "geisa/api/sensor-req/gapi-conformance-tests", encoded_size,
	    message, "geisa/api/sensor-rsp/gapi-conformance-tests", 0);

	free(message);
	return return_code;
}

/**
 * @brief Function to request a sensor that is not readable from the device
 * under test. This function finds a sensor that does not support reading and
 * sends a request for its readings.
 *
 * @param mosq The mosquitto client instance
 * @param ctx The sensor test context containing information about the device
 * @param request The sensor readings request message to be sent
 * @return EXIT_SUCCESS if the request was sent successfully or no not readable
 * sensor was found on the device, EXIT_FAILURE if there was an error in sending
 * the request or allocating memory for the request
 */
static int request_non_readable_sensor_test(struct mosquitto *mosq,
					    struct sensor_test_ctx *ctx,
					    GeisaSensorReadings_Req *request)
{
	int return_code = EXIT_SUCCESS;
	ctx->test_result = EXIT_SUCCESS;
	ctx->sensor_id_requested = 0;
	size_t len = 0;

	mosquitto_message_callback_set(
	    mosq, check_sensor_non_readable_sensor_message);

	request->sensor_id = malloc(sizeof(*request->sensor_id));
	if (request->sensor_id == NULL) {
		fprintf(stderr,
			"Allocation failed for sensor_id request table\n");
		return EXIT_FAILURE;
	}

	for (int i = 0; i < ctx->sensors_count; i++) {
		if (!ctx->sensor[i].supports_read) {
			len = strlen(ctx->sensor[i].sensor_id) + 1;
			request->sensor_id[0] = malloc(len);
			if (request->sensor_id[0] == NULL) {
				fprintf(
				    stderr,
				    "[Sensor] Allocation failed for sensor_id string\n");
				free(request->sensor_id);
				return EXIT_FAILURE;
			}
			strncpy(request->sensor_id[0], ctx->sensor[i].sensor_id,
				len);
			ctx->sensor_id_requested++;
			break;
		}
	}
	if (ctx->sensor_id_requested != 0) {
		request->sensor_id_count = 1;
		return_code = send_sensor_request(mosq, request);
		if (return_code != EXIT_SUCCESS) {
			fprintf(stderr,
				"[Sensor] Error sending sensor request\n");
		}
		free(request->sensor_id[0]);
	} else {
		fprintf(
		    stdout,
		    "[Sensor] No non-readable sensor found on the device\n");
	}

	free(request->sensor_id);
	return return_code;
}

/**
 * @brief Function to request a sensor that is not present on the device under
 * test.
 *
 * @param mosq The mosquitto client instance
 * @param ctx The sensor test context containing information about the device
 * @param request The sensor readings request message to be sent
 * @return EXIT_SUCCESS if the request was sent successfully, EXIT_FAILURE if
 * there was an error in sending the request or allocating memory for the
 * request
 */
static int request_not_present_sensor_test(struct mosquitto *mosq,
					   struct sensor_test_ctx *ctx,
					   GeisaSensorReadings_Req *request)
{
	int return_code = EXIT_SUCCESS;
	ctx->test_result = EXIT_SUCCESS;
	size_t len = 0;

	mosquitto_message_callback_set(mosq,
				       check_sensor_not_present_sensor_message);

	request->sensor_id = malloc(sizeof(*request->sensor_id));
	if (request->sensor_id == NULL) {
		fprintf(stderr,
			"Allocation failed for sensor_id request table\n");
		return EXIT_FAILURE;
	}
	len = sizeof("not_present_sensor");
	request->sensor_id[0] = malloc(len);
	if (request->sensor_id[0] == NULL) {
		fprintf(stderr,
			"[Sensor] Allocation failed for sensor_id string\n");
		free(request->sensor_id);
		return EXIT_FAILURE;
	}
	strncpy(request->sensor_id[0], "not_present_sensor", len);
	request->sensor_id_count = 1;
	return_code = send_sensor_request(mosq, request);
	if (return_code != EXIT_SUCCESS) {
		fprintf(stderr, "[Sensor] Error sending sensor request\n");
	}

	free(request->sensor_id[0]);
	free(request->sensor_id);
	return return_code;
}

/**
 * @brief Function to request each readable sensor from the device under test
 *
 * @param mosq The mosquitto client instance
 * @param ctx The sensor test context containing information about the device
 * @param request The sensor readings request message to be sent
 * @return EXIT_SUCCESS if the request was sent successfully, EXIT_FAILURE if
 * there was an error in sending the request or allocating memory for the
 * request
 */
static int request_each_sensor_sensor_test(struct mosquitto *mosq,
					   struct sensor_test_ctx *ctx,
					   GeisaSensorReadings_Req *request)
{
	int return_code = EXIT_SUCCESS;
	ctx->test_result = EXIT_SUCCESS;
	ctx->sensor_id_requested = 0;
	size_t len = 0;

	mosquitto_message_callback_set(
	    mosq, check_sensor_request_each_sensor_message);

	request->sensor_id =
	    malloc((size_t)ctx->sensors_count * sizeof(*request->sensor_id));
	if (request->sensor_id == NULL) {
		fprintf(stderr,
			"Allocation failed for sensor_id request table\n");
		return EXIT_FAILURE;
	}
	for (int i = 0; i < ctx->sensors_count; i++) {
		len = strlen(ctx->sensor[i].sensor_id) + 1;
		request->sensor_id[i] = malloc(len);
		if (request->sensor_id[i] == NULL) {
			fprintf(
			    stderr,
			    "[Sensor] Allocation failed for sensor_id string\n");
			for (int j = 0; j < i; j++) {
				free(request->sensor_id[j]);
			}
			free(request->sensor_id);
			return EXIT_FAILURE;
		}
		if (ctx->sensor[i].supports_read) {
			strncpy(request->sensor_id[i], ctx->sensor[i].sensor_id,
				len);
			ctx->sensor_id_requested++;
		}
	}
	request->sensor_id_count = ctx->sensor_id_requested;
	return_code = send_sensor_request(mosq, request);
	if (return_code != EXIT_SUCCESS) {
		fprintf(stderr, "[Sensor] Error sending sensor request\n");
	}

	for (int i = 0; i < ctx->sensors_count; i++) {
		free(request->sensor_id[i]);
	}
	free(request->sensor_id);
	return return_code;
}

/**
 * @brief Main function for sensor API tests, initializes MQTT communication,
 * sets appropriate message callback based on command line argument, sends
 * discovery request and sensor request to check sensor response message
 *
 * @param argc Argument count from command line
 * @param argv Argument vector from command line, expects one argument
 * specifying the callback type to test
 * @return EXIT_SUCCESS if all tests pass, EXIT_FAILURE if any test fails or if
 * there is an error in setup
 */
int main(int argc, char *argv[])
{
	GeisaSensorReadings_Req request = GeisaSensorReadings_Req_init_default;
	struct mosquitto *mosq = NULL;
	int return_code = 0;
	time_t start = 0;

	if (argc != 2) {
		fprintf(stderr, "Usage: %s <sensor_test_type>\n", argv[0]);
		fprintf(stderr, "sensor test available:\n"
				"* request_each_sensor\n"
				"* request_not_present_sensor_test\n"
				"* request_non_readable_sensor_test\n");
		return EXIT_FAILURE;
	}
	struct sensor_test_ctx *ctx = calloc(1, sizeof(struct sensor_test_ctx));
	if (!ctx) {
		fprintf(stderr,
			"Error allocating memory for sensor test context\n");
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
			    "[Sensor] Connection timed out after %d seconds\n",
			    TIMEOUT_S);
			return_code = EXIT_FAILURE;
			goto disconnect;
		}
	}

	if (!isConnected) {
		fprintf(stderr, "[Sensor] Failed to connect to broker\n");
		return_code = EXIT_FAILURE;
		goto disconnect;
	}

	mosquitto_message_callback_set(mosq, get_discovery_information);
	return_code = send_discovery_request(mosq);
	if (return_code != EXIT_SUCCESS) {
		fprintf(stderr, "[Sensor] Error sending discovery request\n");
		goto disconnect;
	}

	// Set running back to true after sending the discovery request as
	// mosquitto publish callback set running to false after sending the
	// message
	running = true;

	if (strcmp(argv[1], "request_each_sensor") == 0) {
		return_code =
		    request_each_sensor_sensor_test(mosq, ctx, &request);
	} else if (strcmp(argv[1], "request_not_present_sensor_test") == 0) {
		return_code =
		    request_not_present_sensor_test(mosq, ctx, &request);
	} else if (strcmp(argv[1], "request_non_readable_sensor_test") == 0) {
		return_code =
		    request_non_readable_sensor_test(mosq, ctx, &request);
	} else {
		fprintf(stderr, "Invalid sensor test type: %s\n", argv[1]);
		return_code = EXIT_FAILURE;
		goto disconnect;
	}

disconnect:
	api_communication_deinit(mosq);
exit:
	return_code = return_code ? return_code : ctx->test_result;
	free(ctx->sensor);
	free(ctx);
	return return_code;
}
