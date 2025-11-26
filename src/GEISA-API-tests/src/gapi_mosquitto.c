/**
 * @file gapi_mosquitto.c
 * @brief Definition file for GEISA MQTT communication using the Mosquitto
 * library
 * @copyright Copyright (C) 2025 Southern California Edison
 */

#include "gapi_mosquitto.h"

const int MOSQUITTO_KEEP_ALIVE = 60;

static int sent_mid;

static void handle_signal(int signal)
{
	fprintf(stderr, "Caught signal %d, disconnecting...\n", signal);
	running = false;
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
}

struct mosquitto *api_communication_init(const char *broker, int port)
{
	struct mosquitto *mosq = NULL;
	int return_code = 0;

	mosquitto_lib_init();

	mosq = mosquitto_new(NULL, true, NULL);
	if (!mosq) {
		fprintf(stderr, "Error: mosquitto_new() failed\n");
		goto cleanup;
	}

	mosquitto_connect_callback_set(mosq, on_connect);
	mosquitto_disconnect_callback_set(mosq, on_disconnect);
	mosquitto_publish_callback_set(mosq, on_publish);
	mosquitto_message_callback_set(mosq, on_message);

	signal(SIGINT, handle_signal);
	signal(SIGTERM, handle_signal);

	mosquitto_loop(mosq, -1, 1);

	return_code =
	    mosquitto_connect(mosq, broker, port, MOSQUITTO_KEEP_ALIVE);
	if (return_code != MOSQ_ERR_SUCCESS) {
		fprintf(stderr, "Error: could not connect to %s: %s\n", broker,
			mosquitto_strerror(return_code));
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
