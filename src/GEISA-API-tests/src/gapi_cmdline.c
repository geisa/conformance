/**
 * @file gapi_cmdline.c
 * @brief Command-line interface for MQTT publish/subscribe using Mosquitto
 * @copyright Copyright (C) 2025 Southern California Edison
 */
#include "gapi_mosquitto.h"

volatile int running = 1;

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
	int port = 1883;
	int rc = 0;

	mosq = api_communication_init(broker, port);
	if (!mosq) {
		rc = EXIT_FAILURE;
		goto exit;
	}

	if(strcmp(mode, "sub") == 0) {
		rc = api_subscribe(mosq, topic);
		if(rc)
			goto disconnect;

		fprintf(stdout, "Subscribed to %s on %s — waiting for messages...\n",
			topic, broker);

	} else if(strcmp(mode, "pub") == 0) {
		rc = api_publish(mosq, topic, message);
		if(rc)
			goto disconnect;

		fprintf(stdout, "Published to %s on %s: %s\n", topic, broker, message);
	} else {
		fprintf(stderr, "Unknown mode: %s\n", mode);
		running = 0;
	}

	while (running) {
		mosquitto_loop(mosq, -1, 1);
		sleep(1);
	}

disconnect:
	api_communication_deinit(mosq);
exit:
	return rc;
}
