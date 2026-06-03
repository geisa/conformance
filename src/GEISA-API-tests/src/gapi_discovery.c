/**
 * @file gapi_discovery.c
 * @brief Test discovery API messages
 * @copyright Copyright (C) 2026 Southern California Edison
 */
#include "gapi_mosquitto.h"
#include "pb.h"
#include "pb_decode.h"
#include "pb_encode.h"
#include "schemas/discovery.pb.h"

volatile bool running = true;
volatile bool isConnected = false;
volatile bool rr_disconnect = false;

static void check_geisa_status_message(struct mosquitto *mosq, void *obj,
				       const struct mosquitto_message *msg)
{
	GeisaPlatformDiscovery_Rsp response =
	    GeisaPlatformDiscovery_Rsp_init_default;
	(void)mosq;
	int *test_result = obj;
	pb_istream_t istream;
	bool status = false;

	*test_result = EXIT_SUCCESS;

	istream = pb_istream_from_buffer(msg->payload, msg->payloadlen);
	status =
	    pb_decode(&istream, GeisaPlatformDiscovery_Rsp_fields, &response);

	if (!status) {
		fprintf(
		    stderr,
		    "[Discovery] Error decoding platform discovery response\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response.has_status == false) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing status message\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response.status.code != GeisaStatusCode_GEISA_STATUS_SUCCESS) {
		fprintf(
		    stderr,
		    "[Discovery] Error: geisa status response not success\n");
		*test_result = EXIT_FAILURE;
	}

	if (!response.status.message || !response.status.message[0]) {
		fprintf(stderr,
			"[Discovery] Error: geisa status response missing "
			"message information\n");
		*test_result = EXIT_FAILURE;
	}

disconnect:
	pb_release(GeisaPlatformDiscovery_Rsp_fields, &response);
	printf("[Discovery] geisa test_result: %d\n", *test_result);
	rr_disconnect = true;
}

static void check_discovery_geisa_message(struct mosquitto *mosq, void *obj,
					  const struct mosquitto_message *msg)
{
	GeisaPlatformDiscovery_Rsp response =
	    GeisaPlatformDiscovery_Rsp_init_default;
	(void)mosq;
	int *test_result = obj;
	pb_istream_t istream;
	bool status = false;

	*test_result = EXIT_SUCCESS;

	istream = pb_istream_from_buffer(msg->payload, msg->payloadlen);
	status =
	    pb_decode(&istream, GeisaPlatformDiscovery_Rsp_fields, &response);

	if (!status) {
		fprintf(stderr, "[Discovery] Error decoding platform "
				"discovery response\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response.has_geisa == false) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing geisa message\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response.geisa.pillar_api == false) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing pillar api could not be false\n");
		*test_result = EXIT_FAILURE;
	}

disconnect:
	pb_release(GeisaPlatformDiscovery_Rsp_fields, &response);
	printf("[Discovery] geisa test_result: %d\n", *test_result);
	rr_disconnect = true;
}

static void check_device_top_module(GeisaPlatformDiscovery_Module top_module,
				    int *test_result)
{
	if (!top_module.manufacturer[0]) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing top module manufacturer information\n");
		*test_result = EXIT_FAILURE;
	}

	if (!top_module.model[0]) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing top module model information\n");
		*test_result = EXIT_FAILURE;
	}

	if (!top_module.serial_number[0]) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing top module serial number information\n");
		*test_result = EXIT_FAILURE;
	}

	if (!top_module.hw_revision[0]) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing top module hardware revision information\n");
		*test_result = EXIT_FAILURE;
	}

	if (!top_module.fw_revision[0]) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing top module firmware revision information\n");
		*test_result = EXIT_FAILURE;
	}
}

static void check_device_sub_modules(GeisaPlatformDiscovery_Module *sub_module,
				     size_t sub_module_count, int *test_result)
{
	if (sub_module_count == 0) {
		return;
	}

	if (sub_module == NULL) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing sub module information\n");
		*test_result = EXIT_FAILURE;
		return;
	}

	size_t loop_index = 0;
	for (loop_index = 0; loop_index < sub_module_count; loop_index++) {
		if (!sub_module[loop_index].manufacturer[0]) {
			fprintf(
			    stderr,
			    "[Discovery] Error: platform discovery response "
			    "missing sub module number %ld manufacturer "
			    "information\n",
			    loop_index);
			*test_result = EXIT_FAILURE;
		}
		if (!sub_module[loop_index].model[0]) {
			fprintf(
			    stderr,
			    "[Discovery] Error: platform discovery response "
			    "missing sub module number %ld model "
			    "information\n",
			    loop_index);
			*test_result = EXIT_FAILURE;
		}
		if (!sub_module[loop_index].serial_number[0]) {
			fprintf(
			    stderr,
			    "[Discovery] Error: platform discovery response "
			    "missing sub module number %ld serial number "
			    "information\n",
			    loop_index);
			*test_result = EXIT_FAILURE;
		}
		if (!sub_module[loop_index].hw_revision[0]) {
			fprintf(
			    stderr,
			    "[Discovery] Error: platform discovery response "
			    "missing sub module number %ld hardware "
			    "revision information\n",
			    loop_index);
			*test_result = EXIT_FAILURE;
		}
		if (!sub_module[loop_index].fw_revision[0]) {
			fprintf(
			    stderr,
			    "[Discovery] Error: platform discovery response "
			    "missing sub module number %ld firmware "
			    "revision information\n",
			    loop_index);
			*test_result = EXIT_FAILURE;
		}
	}
}

static void check_discovery_device_message(struct mosquitto *mosq, void *obj,
					   const struct mosquitto_message *msg)
{
	GeisaPlatformDiscovery_Rsp response =
	    GeisaPlatformDiscovery_Rsp_init_default;
	(void)mosq;
	int *test_result = obj;
	pb_istream_t istream;
	bool status = false;

	*test_result = EXIT_SUCCESS;

	istream = pb_istream_from_buffer(msg->payload, msg->payloadlen);
	status =
	    pb_decode(&istream, GeisaPlatformDiscovery_Rsp_fields, &response);

	if (!status) {
		fprintf(stderr, "[Discovery] Error decoding platform "
				"discovery response\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response.has_device == false) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing device message\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response.device.has_top_module == false) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing device top module information\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

	check_device_top_module(response.device.top_module, test_result);

	check_device_sub_modules(response.device.sub_module,
				 response.device.sub_module_count, test_result);

disconnect:
	pb_release(GeisaPlatformDiscovery_Rsp_fields, &response);
	printf("[Discovery] device test_result: %d\n", *test_result);
	rr_disconnect = true;
}

static void
check_discovery_operator_message(struct mosquitto *mosq, void *obj,
				 const struct mosquitto_message *msg)
{
	GeisaPlatformDiscovery_Rsp response =
	    GeisaPlatformDiscovery_Rsp_init_default;
	(void)mosq;
	int *test_result = obj;
	pb_istream_t istream;
	bool status = false;

	*test_result = EXIT_SUCCESS;

	istream = pb_istream_from_buffer(msg->payload, msg->payloadlen);
	status =
	    pb_decode(&istream, GeisaPlatformDiscovery_Rsp_fields, &response);

	if (!status) {
		fprintf(stderr, "[Discovery] Error decoding platform "
				"discovery response\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response.has_operator == false) {
		fprintf(stdout,
			"[Discovery] Info: platform discovery response "
			"not provisioning optional operator information\n");
		goto disconnect;
	}

	if (!response.operator.operator_name[0]) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing operator name information\n");
		*test_result = EXIT_FAILURE;
	}

	if (!response.operator.operator_identifier[0]) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing operator identifier information\n");
		*test_result = EXIT_FAILURE;
	}

disconnect:
	pb_release(GeisaPlatformDiscovery_Rsp_fields, &response);
	printf("[Discovery] operator test_result: %d\n", *test_result);
	rr_disconnect = true;
}

static void
check_discovery_metrology_geisa_message(struct mosquitto *mosq, void *obj,
					const struct mosquitto_message *msg)
{
	GeisaPlatformDiscovery_Rsp response =
	    GeisaPlatformDiscovery_Rsp_init_default;
	(void)mosq;
	int *test_result = obj;
	pb_istream_t istream;
	bool status = false;

	*test_result = EXIT_SUCCESS;

	istream = pb_istream_from_buffer(msg->payload, msg->payloadlen);
	status =
	    pb_decode(&istream, GeisaPlatformDiscovery_Rsp_fields, &response);

	if (!status) {
		fprintf(stderr, "[Discovery] Error decoding platform "
				"discovery response\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response.has_metrology == false) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing metrology information\n");
		*test_result = EXIT_FAILURE;
	}

disconnect:
	pb_release(GeisaPlatformDiscovery_Rsp_fields, &response);
	printf("[Discovery] metrology test_result: %d\n", *test_result);
	rr_disconnect = true;
}

static void check_discovery_sensor_message(struct mosquitto *mosq, void *obj,
					   const struct mosquitto_message *msg)
{
	GeisaPlatformDiscovery_Rsp response =
	    GeisaPlatformDiscovery_Rsp_init_default;
	(void)mosq;
	int *test_result = obj;
	pb_istream_t istream;
	bool status = false;

	*test_result = EXIT_SUCCESS;

	istream = pb_istream_from_buffer(msg->payload, msg->payloadlen);
	status =
	    pb_decode(&istream, GeisaPlatformDiscovery_Rsp_fields, &response);

	if (!status) {
		fprintf(stderr, "[Discovery] Error decoding platform "
				"discovery response\n");
		*test_result = EXIT_FAILURE;
		rr_disconnect = true;
		goto disconnect;
	}

	if (response.has_sensor == false) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing sensor information\n");
		*test_result = EXIT_FAILURE;
	}

disconnect:
	pb_release(GeisaPlatformDiscovery_Rsp_fields, &response);
	printf("[Discovery] sensor test_result: %d\n", *test_result);
	rr_disconnect = true;
}

static void check_discovery_network_message(struct mosquitto *mosq, void *obj,
					    const struct mosquitto_message *msg)
{
	GeisaPlatformDiscovery_Rsp response =
	    GeisaPlatformDiscovery_Rsp_init_default;
	(void)mosq;
	int *test_result = obj;
	pb_istream_t istream;
	bool status = false;

	*test_result = EXIT_SUCCESS;

	istream = pb_istream_from_buffer(msg->payload, msg->payloadlen);
	status =
	    pb_decode(&istream, GeisaPlatformDiscovery_Rsp_fields, &response);

	if (!status) {
		fprintf(stderr, "[Discovery] Error decoding platform "
				"discovery response\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response.has_network == false) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing network information\n");
		*test_result = EXIT_FAILURE;
	}

disconnect:
	pb_release(GeisaPlatformDiscovery_Rsp_fields, &response);
	printf("[Discovery] network test_result: %d\n", *test_result);
	rr_disconnect = true;
}

static void
check_discovery_waveform_message(struct mosquitto *mosq, void *obj,
				 const struct mosquitto_message *msg)
{
	GeisaPlatformDiscovery_Rsp response =
	    GeisaPlatformDiscovery_Rsp_init_default;
	(void)mosq;
	int *test_result = obj;
	pb_istream_t istream;
	bool status = false;

	*test_result = EXIT_SUCCESS;

	istream = pb_istream_from_buffer(msg->payload, msg->payloadlen);
	status =
	    pb_decode(&istream, GeisaPlatformDiscovery_Rsp_fields, &response);

	if (!status) {
		fprintf(stderr, "[Discovery] Error decoding platform "
				"discovery response\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response.has_waveform == false) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing waveform information\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response.waveform.streams_count != 0) {
		if (response.waveform.streams == NULL) {
			fprintf(stderr, "[Discovery] Error: platform discovery "
					"response missing waveform streams "
					"information\n");
			*test_result = EXIT_FAILURE;
			goto disconnect;
		}

		size_t loop_index = 0;
		for (loop_index = 0;
		     loop_index < response.waveform.streams_count;
		     loop_index++) {
			if (!response.waveform.streams[loop_index]
				 .stream_id[0]) {
				fprintf(stderr,
					"[Discovery] Error: platform discovery "
					"response missing waveform instance "
					"number %ld stream_id "
					"information\n",
					loop_index);
				*test_result = EXIT_FAILURE;
			}
		}
	}

disconnect:
	pb_release(GeisaPlatformDiscovery_Rsp_fields, &response);
	printf("[Discovery] waveform test_result: %d\n", *test_result);
	rr_disconnect = true;
}

int main(int argc, char *argv[])
{
	GeisaPlatformDiscovery_Req request =
	    GeisaPlatformDiscovery_Req_init_default;
	struct mosquitto *mosq = NULL;
	uint8_t *message = NULL;
	size_t encoded_size = 0;
	pb_ostream_t ostream;
	int return_code = 0;
	int test_result = 0;
	bool status = false;

	if (argc != 2) {
		fprintf(stderr, "Usage: %s <callback_type>\n", argv[0]);
		fprintf(stderr, "callback_type available:\n"
				"* status\n"
				"* geisa\n"
				"* device \n"
				"* operator \n"
				"* metrology \n"
				"* sensor\n"
				"* network\n"
				"* waveform\n");
		return EXIT_FAILURE;
	}

	mosq = api_communication_init();
	if (!mosq) {
		return_code = EXIT_FAILURE;
		goto exit;
	}

	if (strcmp(argv[1], "status") == 0) {
		mosquitto_message_callback_set(mosq,
					       check_geisa_status_message);
	} else if (strcmp(argv[1], "geisa") == 0) {
		mosquitto_message_callback_set(mosq,
					       check_discovery_geisa_message);
	} else if (strcmp(argv[1], "device") == 0) {
		mosquitto_message_callback_set(mosq,
					       check_discovery_device_message);
	} else if (strcmp(argv[1], "operator") == 0) {
		mosquitto_message_callback_set(
		    mosq, check_discovery_operator_message);
	} else if (strcmp(argv[1], "metrology") == 0) {
		mosquitto_message_callback_set(
		    mosq, check_discovery_metrology_geisa_message);
	} else if (strcmp(argv[1], "sensor") == 0) {
		mosquitto_message_callback_set(mosq,
					       check_discovery_sensor_message);
	} else if (strcmp(argv[1], "network") == 0) {
		mosquitto_message_callback_set(mosq,
					       check_discovery_network_message);
	} else if (strcmp(argv[1], "waveform") == 0) {
		mosquitto_message_callback_set(
		    mosq, check_discovery_waveform_message);
	} else {
		fprintf(stderr, "Invalid callback type: %s\n", argv[1]);
		return_code = EXIT_FAILURE;
		goto disconnect;
	}

	mosquitto_user_data_set(mosq, &test_result);

	while (running && !isConnected) {
		mosquitto_loop(mosq, -1, 1);
		sleep(1);
	}

	if (!isConnected) {
		fprintf(stderr, "Failed to connect to broker\n");
		return_code = EXIT_FAILURE;
		goto disconnect;
	}

	status = pb_get_encoded_size(
	    &encoded_size, GeisaPlatformDiscovery_Req_fields, &request);
	if (!status) {
		fprintf(stderr, "[Discovery] Error calculating encoded size for"
				"platform discovery request\n");
		return_code = EXIT_FAILURE;
		goto disconnect;
	}

	message = malloc(encoded_size);
	if (message == NULL) {
		fprintf(stderr, "[Discovery] Error allocating memory for "
				"platform discovery request\n");
		return_code = EXIT_FAILURE;
		goto disconnect;
	}
	ostream = pb_ostream_from_buffer(message, encoded_size);
	status =
	    pb_encode(&ostream, GeisaPlatformDiscovery_Req_fields, &request);
	if (!status) {
		fprintf(stderr, "[Discovery] Error encoding platform discovery "
				"request\n");
		return_code = EXIT_FAILURE;
		free(message);
		goto disconnect;
	}
	return_code = api_request_response(
	    mosq, "geisa/api/platform/discovery/req/gapi-conformance-tests",
	    encoded_size, message,
	    "geisa/api/platform/discovery/rsp/gapi-conformance-tests", 1);

	free(message);
	pb_release(GeisaPlatformDiscovery_Req_fields, &request);

disconnect:
	api_communication_deinit(mosq);
exit:
	return return_code || test_result;
}
