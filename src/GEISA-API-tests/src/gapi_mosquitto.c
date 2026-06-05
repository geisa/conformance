/**
 * @file gapi_mosquitto.c
 * @brief Definition file for GEISA MQTT communication using the Mosquitto
 * library
 * @copyright Copyright (C) 2025 Southern California Edison
 */

#include "gapi_mosquitto.h"

const int MOSQUITTO_KEEP_ALIVE = 60;
enum { LINE_SIZE = 256, BASE_10 = 10 };

const int RR_TIMEOUT_S = 5;

static int sent_mid;

/**
 * @brief Function to handle signals for graceful shutdown
 *
 * @param signal The signal number received
 */
static void handle_signal(int signal)
{
	fprintf(stderr, "Caught signal %d, disconnecting...\n", signal);
	running = false;
	rr_disconnect = true;
}

/**
 * @brief Callback function for connection to the MQTT broker
 *
 * @param mosq The mosquitto client instance
 * @param obj User-defined data (not used in this implementation)
 * @param return_code The return code from the connection attempt
 */
static void on_connect(struct mosquitto *mosq, void *obj, int return_code)
{
	(void)obj;
	if (return_code == 0) {
		fprintf(stdout, "[connected] OK\n");
		isConnected = true;
	} else {
		fprintf(stderr, "[connect] failed, return_code=%d\n",
			return_code);
		running = false;
		mosquitto_disconnect(mosq);
	}
}

/**
 * @brief Callback function for disconnection from the MQTT broker
 *
 * @param mosq The mosquitto client instance
 * @param obj User-defined data (not used in this implementation)
 * @param return_code The return code from the disconnection event
 */
static void on_disconnect(struct mosquitto *mosq, void *obj, int return_code)
{
	(void)obj;
	(void)mosq;
	fprintf(stdout, "[disconnected] return_code=%d\n", return_code);
	isConnected = false;
}

/**
 * @brief Callback function for message publication
 * This function set the running flag to false when the published message is
 * acknowledged by the broker, allowing the main loop to exit gracefully.
 *
 * @param mosq The mosquitto client instance
 * @param obj User-defined data (not used in this implementation)
 * @param mid The message ID of the published message
 */
static void on_publish(struct mosquitto *mosq, void *obj, int mid)
{
	(void)obj;
	(void)mosq;
	if (mid == sent_mid) {
		running = false;
	} else {
		fprintf(stderr, "[publish] mid=%d (not expected %d)\n", mid,
			sent_mid);
		exit(1);
	}
}

/**
 * @brief Callback function for incoming messages
 * This function prints the topic and payload of the received message, and sets
 * the rr_disconnect flag to true to indicate that a response has been received
 * for a request-response operation.
 *
 * @param mosq The mosquitto client instance
 * @param obj User-defined data (not used in this implementation)
 * @param msg The received MQTT message
 */
static void on_message(struct mosquitto *mosq, void *obj,
		       const struct mosquitto_message *msg)
{
	(void)obj;
	(void)mosq;
	fprintf(stdout, "[msg] topic=%s payload=%.*s\n", msg->topic,
		msg->payloadlen, (char *)msg->payload);
	rr_disconnect = true;
}

/**
 * @brief Reads MQTT configuration from a file and populates the mqtt_config
 * structure
 *
 * The function reads the MQTT configuration parameters (HOST, PORT, USERID,
 * PASSWORD) from the /etc/geisa/mqtt.conf file. Each line in the configuration
 * file should be in the format "KEY=VALUE". The function parses each line and
 * updates the corresponding fields in the mqtt_config structure.
 *
 * @param cfg Pointer to the mqtt_config structure to be populated with the
 * configuration values
 * @return 0 on success, -1 on failure (e.g., if the file cannot be opened)
 */
static int read_mqtt_conf_file(mqtt_config *cfg)
{
	FILE *file = fopen("/etc/geisa/mqtt.conf", "r");
	if (!file) {
		fprintf(stderr, "Error: Could not open mqtt.conf\n");
		return -1;
	}

	char line[LINE_SIZE];

	while (fgets(line, sizeof(line), file)) {
		char key[MQTT_CONFIG_FIELD_SIZE] = {0};
		char value[MQTT_CONFIG_FIELD_SIZE] = {0};
		if (sscanf(line, "%127[^=]=%127s", key, value) == 2) {
			if (strcmp(key, "HOST") == 0) {
				snprintf(cfg->mqtt_host, sizeof(cfg->mqtt_host),
					 "%s", value);
			} else if (strcmp(key, "PORT") == 0) {
				cfg->mqtt_port =
				    (int)strtol(value, NULL, BASE_10);
			} else if (strcmp(key, "USERID") == 0) {
				snprintf(cfg->mqtt_id, sizeof(cfg->mqtt_id),
					 "%s", value);
			} else if (strcmp(key, "PASSWORD") == 0) {
				snprintf(cfg->mqtt_password,
					 sizeof(cfg->mqtt_password), "%s",
					 value);
			}
		}
	}

	fclose(file);
	return 0;
}

/**
 * @brief Initializes the MQTT communication by reading the configuration,
 * setting up the Mosquitto client, and connecting to the MQTT broker
 */
struct mosquitto *api_communication_init()
{
	struct mosquitto *mosq = NULL;
	int return_code = 0;
	mqtt_config cfg = {0};

	return_code = read_mqtt_conf_file(&cfg);
	if (return_code != 0) {
		fprintf(stderr, "Error: Failed to read MQTT configuration\n");
		return NULL;
	}
	mosquitto_lib_init();

	mosq = mosquitto_new(NULL, true, NULL);
	if (!mosq) {
		fprintf(stderr, "Error: mosquitto_new() failed\n");
		goto cleanup;
	}

	mosquitto_username_pw_set(mosq, cfg.mqtt_id, cfg.mqtt_password);
	mosquitto_connect_callback_set(mosq, on_connect);
	mosquitto_disconnect_callback_set(mosq, on_disconnect);
	mosquitto_publish_callback_set(mosq, on_publish);
	mosquitto_message_callback_set(mosq, on_message);

	signal(SIGINT, handle_signal);
	signal(SIGTERM, handle_signal);

	mosquitto_loop(mosq, -1, 1);

	return_code = mosquitto_connect(mosq, cfg.mqtt_host, cfg.mqtt_port,
					MOSQUITTO_KEEP_ALIVE);
	if (return_code != MOSQ_ERR_SUCCESS) {
		fprintf(stderr, "Error: could not connect to %s: %s\n",
			cfg.mqtt_host, mosquitto_strerror(return_code));
		goto destroy;
	}

	return mosq;

destroy:
	mosquitto_destroy(mosq);
cleanup:
	mosquitto_lib_cleanup();
	return NULL;
}

/**
 * @brief Deinitializes the MQTT communication by disconnecting from the broker,
 * destroying the Mosquitto client, and cleaning up the Mosquitto library
 *
 * @param mosq The mosquitto client instance to be deinitialized
 */
void api_communication_deinit(struct mosquitto *mosq)
{
	mosquitto_disconnect(mosq);
	mosquitto_destroy(mosq);
	mosquitto_lib_cleanup();
}

/**
 * @brief Subscribes to a specified MQTT topic with a given QoS level
 *
 * @param mosq The mosquitto client instance
 * @param topic The MQTT topic to subscribe to
 * @param qos The Quality of Service level for the subscription (0, 1, or 2)
 * @return 0 on success, or a non-zero error code on failure
 */
int api_subscribe(struct mosquitto *mosq, const char *topic, int qos)
{
	int return_code = 0;

	return_code = mosquitto_subscribe(mosq, NULL, topic, qos);
	if (return_code != MOSQ_ERR_SUCCESS) {
		fprintf(stderr, "Subscribe failed: %s\n",
			mosquitto_strerror(return_code));
		return return_code;
	}

	return 0;
}

/**
 * @brief Publishes a message to a specified MQTT topic with a given QoS level
 *
 * @param mosq The mosquitto client instance
 * @param topic The MQTT topic to publish to
 * @param message_size The size of the message payload in bytes
 * @param message The message payload as a byte array
 * @param qos The Quality of Service level for the publication (0, 1, or 2)
 * @return 0 on success, or a non-zero error code on failure
 */
int api_publish(struct mosquitto *mosq, const char *topic,
		const size_t message_size, const uint8_t *message, int qos)
{
	int return_code = 0;

	return_code = mosquitto_publish(mosq, &sent_mid, topic,
					(int)message_size, message, qos, false);
	if (return_code != MOSQ_ERR_SUCCESS) {
		fprintf(stderr, "Publish failed: %s\n",
			mosquitto_strerror(return_code));
		return return_code;
	}

	return 0;
}

/**
 * @brief Performs a request-response operation by subscribing to a response
 * topic, publishing a request message to a specified topic, and waiting for a
 * response message or timeout
 *
 * @param mosq The mosquitto client instance
 * @param topic The MQTT topic to publish the request message to
 * @param message_size The size of the request message payload in bytes
 * @param message The request message payload as a byte array
 * @param response_topic The MQTT topic to subscribe to for receiving the
 * response
 * @param qos The Quality of Service level for both the subscription and
 * publication (0, 1, or 2)
 * @return 0 on success (response received), -1 on timeout, or a non-zero error
 * code on failure
 */
int api_request_response(struct mosquitto *mosq, const char *topic,
			 const size_t message_size, const uint8_t *message,
			 const char *response_topic, int qos)
{
	int return_code = 0;
	time_t start = 0;
	rr_disconnect = false;

	return_code = api_subscribe(mosq, response_topic, qos);
	if (return_code != 0) {
		return return_code;
	}
	return_code = api_publish(mosq, topic, message_size, message, qos);
	if (return_code != 0) {
		return return_code;
	}

	start = time(NULL);
	while (!rr_disconnect) {
		mosquitto_loop(mosq, -1, 1);
		if (difftime(time(NULL), start) > RR_TIMEOUT_S) {
			fprintf(stderr, "Request timed out after %d seconds\n",
				RR_TIMEOUT_S);
			return -1;
		}
	}
	return 0;
}
