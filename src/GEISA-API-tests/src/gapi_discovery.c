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

static void check_discovery_geisa_message(struct mosquitto *mosq, void *obj,
					  const struct mosquitto_message *msg)
{
	GeisaPlatformDiscoveryRsp *response = NULL;
	(void)mosq;
	int *test_result = obj;

	*test_result = EXIT_SUCCESS;

	response = geisa_platform_discovery__rsp__unpack(
	    NULL, msg->payloadlen, (uint8_t *)msg->payload);

	if (response == NULL) {
		fprintf(stderr, "[Discovery] Error unpacking platform "
				"discovery response\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response->geisa == NULL) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing geisa message\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response->geisa->pillar_api == false) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing pillar api could not be false\n");
		*test_result = EXIT_FAILURE;
	}

	geisa_platform_discovery__rsp__free_unpacked(response, NULL);

disconnect:
	printf("[Discovery] geisa test_result: %d\n", *test_result);
	rr_disconnect = true;
}

static void check_device_top_module(GeisaPlatformDiscoveryModule *top_module,
				    int *test_result)
{
	if (top_module == NULL) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing top module information\n");
		*test_result = EXIT_FAILURE;
		return;
	}

	if (!top_module->manufacturer[0]) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing top module manufacturer information\n");
		*test_result = EXIT_FAILURE;
	}

	if (!top_module->model[0]) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing top module model information\n");
		*test_result = EXIT_FAILURE;
	}

	if (!top_module->serial_number[0]) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing top module serial number information\n");
		*test_result = EXIT_FAILURE;
	}

	if (!top_module->hw_revision[0]) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing top module hardware revision information\n");
		*test_result = EXIT_FAILURE;
	}

	if (!top_module->fw_revision[0]) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing top module firmware revision information\n");
		*test_result = EXIT_FAILURE;
	}
}

static void check_device_sub_modules(GeisaPlatformDiscoveryModule **sub_module,
				     size_t n_sub_module, int *test_result)
{
	if (n_sub_module == 0) {
		return;
	}

	size_t loop_index = 0;
	for (loop_index = 0; loop_index < n_sub_module; loop_index++) {
		if (sub_module[loop_index] == NULL) {
			fprintf(
			    stderr,
			    "[Discovery] Error: platform discovery response "
			    "missing sub module number %ld information\n",
			    loop_index);
			*test_result = EXIT_FAILURE;
			continue;
		}
		if (!sub_module[loop_index]->manufacturer[0]) {
			fprintf(
			    stderr,
			    "[Discovery] Error: platform discovery response "
			    "missing sub module number %ld manufacturer "
			    "information\n",
			    loop_index);
			*test_result = EXIT_FAILURE;
		}
		if (!sub_module[loop_index]->model[0]) {
			fprintf(
			    stderr,
			    "[Discovery] Error: platform discovery response "
			    "missing sub module number %ld model "
			    "information\n",
			    loop_index);
			*test_result = EXIT_FAILURE;
		}
		if (!sub_module[loop_index]->serial_number[0]) {
			fprintf(
			    stderr,
			    "[Discovery] Error: platform discovery response "
			    "missing sub module number %ld serial number "
			    "information\n",
			    loop_index);
			*test_result = EXIT_FAILURE;
		}
		if (!sub_module[loop_index]->hw_revision[0]) {
			fprintf(
			    stderr,
			    "[Discovery] Error: platform discovery response "
			    "missing sub module number %ld hardware "
			    "revision information\n",
			    loop_index);
			*test_result = EXIT_FAILURE;
		}
		if (!sub_module[loop_index]->fw_revision[0]) {
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
	GeisaPlatformDiscoveryRsp *response = NULL;
	(void)mosq;
	int *test_result = obj;

	*test_result = EXIT_SUCCESS;

	response = geisa_platform_discovery__rsp__unpack(
	    NULL, msg->payloadlen, (uint8_t *)msg->payload);

	if (response == NULL) {
		fprintf(stderr, "[Discovery] Error unpacking platform "
				"discovery response\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response->device == NULL) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing device message\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

	check_device_top_module(response->device->top_module, test_result);
	check_device_sub_modules(response->device->sub_module,
				 response->device->n_sub_module, test_result);

	geisa_platform_discovery__rsp__free_unpacked(response, NULL);

disconnect:
	printf("[Discovery] device test_result: %d\n", *test_result);
	rr_disconnect = true;
}

static void
check_discovery_operator_message(struct mosquitto *mosq, void *obj,
				 const struct mosquitto_message *msg)
{
	GeisaPlatformDiscoveryRsp *response = NULL;
	(void)mosq;
	int *test_result = obj;

	*test_result = EXIT_SUCCESS;

	response = geisa_platform_discovery__rsp__unpack(
	    NULL, msg->payloadlen, (uint8_t *)msg->payload);

	if (response == NULL) {
		fprintf(stderr, "[Discovery] Error unpacking platform "
				"discovery response\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response->operator_ == NULL) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing operator information\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (!response->operator_->operator_name[0]) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing operator name information\n");
		*test_result = EXIT_FAILURE;
	}

	if (!response->operator_->operator_identifier[0]) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing operator identifier information\n");
		*test_result = EXIT_FAILURE;
	}

	geisa_platform_discovery__rsp__free_unpacked(response, NULL);

disconnect:
	printf("[Discovery] operator test_result: %d\n", *test_result);
	rr_disconnect = true;
}

static void
check_discovery_metrology_geisa_message(struct mosquitto *mosq, void *obj,
					const struct mosquitto_message *msg)
{
	GeisaPlatformDiscoveryRsp *response = NULL;
	(void)mosq;
	int *test_result = obj;

	*test_result = EXIT_SUCCESS;

	response = geisa_platform_discovery__rsp__unpack(
	    NULL, msg->payloadlen, (uint8_t *)msg->payload);

	if (response == NULL) {
		fprintf(stderr, "[Discovery] Error unpacking platform "
				"discovery response\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response->metrology == NULL) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing metrology information\n");
		*test_result = EXIT_FAILURE;
	}

	geisa_platform_discovery__rsp__free_unpacked(response, NULL);

disconnect:
	printf("[Discovery] metrology test_result: %d\n", *test_result);
	rr_disconnect = true;
}

static void check_discovery_sensor_message(struct mosquitto *mosq, void *obj,
					   const struct mosquitto_message *msg)
{
	GeisaPlatformDiscoveryRsp *response = NULL;
	(void)mosq;
	int *test_result = obj;

	*test_result = EXIT_SUCCESS;

	response = geisa_platform_discovery__rsp__unpack(
	    NULL, msg->payloadlen, (uint8_t *)msg->payload);

	if (response == NULL) {
		fprintf(stderr, "[Discovery] Error unpacking platform "
				"discovery response\n");
		*test_result = EXIT_FAILURE;
		rr_disconnect = true;
		goto disconnect;
	}

	if (response->sensor == NULL) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing sensor information\n");
		*test_result = EXIT_FAILURE;
	}

	geisa_platform_discovery__rsp__free_unpacked(response, NULL);

disconnect:
	printf("[Discovery] sensor test_result: %d\n", *test_result);
	rr_disconnect = true;
}

static void check_discovery_network_message(struct mosquitto *mosq, void *obj,
					    const struct mosquitto_message *msg)
{
	GeisaPlatformDiscoveryRsp *response = NULL;
	(void)mosq;
	int *test_result = obj;

	*test_result = EXIT_SUCCESS;

	response = geisa_platform_discovery__rsp__unpack(
	    NULL, msg->payloadlen, (uint8_t *)msg->payload);

	if (response == NULL) {
		fprintf(stderr, "[Discovery] Error unpacking platform "
				"discovery response\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response->network == NULL) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing network information\n");
		*test_result = EXIT_FAILURE;
	}

	geisa_platform_discovery__rsp__free_unpacked(response, NULL);

disconnect:
	printf("[Discovery] network test_result: %d\n", *test_result);
	rr_disconnect = true;
}

static void
check_discovery_waveform_message(struct mosquitto *mosq, void *obj,
				 const struct mosquitto_message *msg)
{
	GeisaPlatformDiscoveryRsp *response = NULL;
	(void)mosq;
	int *test_result = obj;

	*test_result = EXIT_SUCCESS;

	response = geisa_platform_discovery__rsp__unpack(
	    NULL, msg->payloadlen, (uint8_t *)msg->payload);

	if (response == NULL) {
		fprintf(stderr, "[Discovery] Error unpacking platform "
				"discovery response\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response->waveform == NULL) {
		fprintf(stderr,
			"[Discovery] Error: platform discovery response "
			"missing waveform information\n");
		*test_result = EXIT_FAILURE;
		goto disconnect;
	}

	if (response->waveform->n_instances != 0) {
		size_t loop_index = 0;
		for (loop_index = 0;
		     loop_index < response->waveform->n_instances;
		     loop_index++) {
			if (response->waveform->instances[loop_index] == NULL) {
				fprintf(stderr,
					"[Discovery] Error: platform discovery "
					"response "
					"missing waveform instance number %ld "
					"information\n",
					loop_index);
				*test_result = EXIT_FAILURE;
				continue;
			}
			if (!response->waveform->instances[loop_index]
				 ->data_connection[0]) {
				fprintf(stderr,
					"[Discovery] Error: platform discovery "
					"response "
					"missing waveform instance "
					"number %ld data connection "
					"information\n",
					loop_index);
				*test_result = EXIT_FAILURE;
			}
		}
	}

	geisa_platform_discovery__rsp__free_unpacked(response, NULL);

disconnect:
	printf("[Discovery] waveform test_result: %d\n", *test_result);
	rr_disconnect = true;
}

int main(int argc, char *argv[])
{
	GeisaPlatformDiscoveryReq request = GEISA_PLATFORM_DISCOVERY__REQ__INIT;
	struct mosquitto *mosq = NULL;
	uint8_t *message = NULL;
	int return_code = 0;
	int test_result = 0;

	if (argc != 2) {
		fprintf(stderr, "Usage: %s <callback_type>\n", argv[0]);
		fprintf(stderr, "callback_type available:\n"
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

	if (strcmp(argv[1], "geisa") == 0) {
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
	return return_code || test_result;
}
