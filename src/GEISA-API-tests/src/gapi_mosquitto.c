// Copyright (C) 2025 Southern California Edison

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mosquitto.h>
#include <signal.h>
#include <unistd.h>

static int sent_mid;
static volatile int running = 1;

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

int main(int argc, char **argv)
{
	if(argc < 4) {
		fprintf(stderr, "Usage:\n  %s sub <broker> <topic>\n  %s pub <broker> <topic> <message>\n",
			argv[0], argv[0]);
		return 1;
	}

	const char *mode = argv[1];
	const char *broker = argv[2];
	const char *topic = argv[3];
	const char *message = (argc >= 5) ? argv[4] : "";
	struct mosquitto *mosq;
	int rc = 0;

	mosquitto_lib_init();

	mosq = mosquitto_new(NULL, true, NULL);
	if(!mosq) {
		fprintf(stderr, "Error: mosquitto_new() failed\n");
		goto cleanup;
	}

	mosquitto_connect_callback_set(mosq, on_connect);
	mosquitto_publish_callback_set(mosq, on_publish);
	mosquitto_message_callback_set(mosq, on_message);

	signal(SIGINT, handle_signal);
	signal(SIGTERM, handle_signal);

	rc = mosquitto_connect(mosq, broker, 1883, 60);
	if(rc != MOSQ_ERR_SUCCESS){
		fprintf(stderr, "Error: could not connect to %s: %s\n", broker,
			mosquitto_strerror(rc));
		goto destroy;
	}

	rc = mosquitto_loop_start(mosq);
	if (rc != MOSQ_ERR_SUCCESS) {
		fprintf(stderr, "Loop start failed: %s\n", mosquitto_strerror(rc));
		goto disconnect;
	}

	if(strcmp(mode, "sub") == 0) {
		rc = mosquitto_subscribe(mosq, NULL, topic, 0);
		if(rc != MOSQ_ERR_SUCCESS) {
			fprintf(stderr, "Subscribe failed: %s\n",
				mosquitto_strerror(rc));
			goto disconnect;
		}

		fprintf(stdout, "Subscribed to %s on %s — waiting for messages...\n",
		       topic, broker);

	} else if(strcmp(mode, "pub") == 0) {
		int mid;
		rc = mosquitto_publish(mosq, &sent_mid, topic,
				       (int)strlen(message), message, 1, false);

		if(rc != MOSQ_ERR_SUCCESS) {
			fprintf(stderr, "Publish failed: %s\n",
				mosquitto_strerror(rc));
			goto disconnect;
		}

		fprintf(stdout, "Published to %s on %s: %s\n", topic, broker, message);
	} else {
		fprintf(stderr, "Unknown mode: %s\n", mode);
		running = 0;
	}

	while (running) {
		sleep(1);
	}

disconnect:
	mosquitto_disconnect(mosq);
	mosquitto_loop_stop(mosq, false);
destroy:
	mosquitto_destroy(mosq);
cleanup:
	mosquitto_lib_cleanup();
	return rc;
}
