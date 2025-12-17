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

static void handle_signal(int signal)
{
	fprintf(stderr, "Caught signal %d, disconnecting...\n", signal);
	running = false;
	rr_disconnect = true;
}

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

static void on_disconnect(struct mosquitto *mosq, void *obj, int return_code)
{
	(void)obj;
	(void)mosq;
	fprintf(stdout, "[disconnected] return_code=%d\n", return_code);
	isConnected = false;
}

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

static void on_message(struct mosquitto *mosq, void *obj,
		       const struct mosquitto_message *msg)
{
	(void)obj;
	(void)mosq;
	fprintf(stdout, "[msg] topic=%s payload=%.*s\n", msg->topic,
		msg->payloadlen, (char *)msg->payload);
	rr_disconnect = true;
}

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

void api_communication_deinit(struct mosquitto *mosq)
{
	mosquitto_disconnect(mosq);
	mosquitto_destroy(mosq);
	mosquitto_lib_cleanup();
}

int api_subscribe(struct mosquitto *mosq, const char *topic)
{
	int return_code = 0;

	return_code = mosquitto_subscribe(mosq, NULL, topic, 0);
	if (return_code != MOSQ_ERR_SUCCESS) {
		fprintf(stderr, "Subscribe failed: %s\n",
			mosquitto_strerror(return_code));
		return return_code;
	}

	return 0;
}

int api_publish(struct mosquitto *mosq, const char *topic, const char *message)
{
	int return_code = 0;

	return_code = mosquitto_publish(
	    mosq, &sent_mid, topic, (int)strlen(message), message, 1, false);
	if (return_code != MOSQ_ERR_SUCCESS) {
		fprintf(stderr, "Publish failed: %s\n",
			mosquitto_strerror(return_code));
		return return_code;
	}

	return 0;
}

int api_request_response(struct mosquitto *mosq, const char *topic,
			 const char *message, const char *response_topic)
{
	int return_code = 0;
	time_t start = 0;
	rr_disconnect = false;

	return_code = api_subscribe(mosq, response_topic);
	if (return_code != 0) {
		return return_code;
	}
	return_code = api_publish(mosq, topic, message);
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
