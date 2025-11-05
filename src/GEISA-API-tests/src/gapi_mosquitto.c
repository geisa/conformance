/**
 * @file gapi_mosquitto.c
 * @brief Definition file for GEISA MQTT communication using the Mosquitto library
 * @copyright Copyright (C) 2025 Southern California Edison
 */

#include "gapi_mosquitto.h"

static int sent_mid;

static void handle_signal(int s)
{
	fprintf(stderr, "Caught signal %d, disconnecting...\n", s);
	running = 0;
}

static void on_connect(struct mosquitto *mosq, void *obj, int rc)
{
	if(rc == 0) {
		fprintf(stdout, "[connected] OK\n");
	} else {
		fprintf(stderr, "[connect] failed, rc=%d\n", rc);
		mosquitto_disconnect(mosq);
	}
}

static void on_disconnect(struct mosquitto *mosq, void *obj, int rc)
{
	fprintf(stdout, "[disconnected] rc=%d\n", rc);
}

static void on_publish(struct mosquitto *mosq, void *obj, int mid)
{
	if(mid == sent_mid){
		running = 0;
	} else {
		fprintf(stderr, "[publish] mid=%d (not expected %d)\n", mid, sent_mid);
		exit(1);
	}
}

static void on_message(struct mosquitto *mosq, void *obj,
		       const struct mosquitto_message *msg)
{
	fprintf(stdout, "[msg] topic=%s payload=%.*s\n", msg->topic,
		msg->payloadlen, (char *)msg->payload);
}

struct mosquitto * api_communication_init(const char *broker, int port)
{
	struct mosquitto *mosq = NULL;
	int rc;

	mosquitto_lib_init();

	mosq = mosquitto_new(NULL, true, NULL);
	if(!mosq) {
		fprintf(stderr, "Error: mosquitto_new() failed\n");
		goto cleanup;
	}

	mosquitto_connect_callback_set(mosq, on_connect);
	mosquitto_disconnect_callback_set(mosq, on_disconnect);
	mosquitto_publish_callback_set(mosq, on_publish);
	mosquitto_message_callback_set(mosq, on_message);

	signal(SIGINT, handle_signal);
	signal(SIGTERM, handle_signal);

	rc = mosquitto_connect(mosq, broker, port, 60);
	if(rc != MOSQ_ERR_SUCCESS){
		fprintf(stderr, "Error: could not connect to %s: %s\n", broker,
			mosquitto_strerror(rc));
		goto destroy;
	}

	rc = mosquitto_loop_start(mosq);
	if (rc != MOSQ_ERR_SUCCESS) {
		fprintf(stderr, "Loop start failed: %s\n",
			mosquitto_strerror(rc));
		goto disconnect;
	}

	return mosq;

disconnect:
	mosquitto_disconnect(mosq);
	mosquitto_loop_stop(mosq, false);
destroy:
	mosquitto_destroy(mosq);
cleanup:
	mosquitto_lib_cleanup();
	return NULL;
}

void api_communication_deinit(struct mosquitto *mosq)
{
	mosquitto_disconnect(mosq);
	mosquitto_loop_stop(mosq, false);
	mosquitto_destroy(mosq);
	mosquitto_lib_cleanup();
}

int api_subscribe(struct mosquitto *mosq, const char *topic)
{
	int rc;

	rc = mosquitto_subscribe(mosq, NULL, topic, 0);
	if(rc != MOSQ_ERR_SUCCESS) {
		fprintf(stderr, "Subscribe failed: %s\n",
			mosquitto_strerror(rc));
		return rc;
	}

	return 0;
}

int api_publish(struct mosquitto *mosq, const char *topic, const char *message)
{
	int rc;

	rc = mosquitto_publish(mosq, &sent_mid, topic,
			       (int)strlen(message), message, 1, false);
	if(rc != MOSQ_ERR_SUCCESS) {
		fprintf(stderr, "Publish failed: %s\n",
			mosquitto_strerror(rc));
		return rc;
	}

	return 0;
}
