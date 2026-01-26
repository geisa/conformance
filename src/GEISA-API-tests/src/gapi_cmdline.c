/**
 * @file gapi_cmdline.c
 * @brief Command-line interface for MQTT publish/subscribe using Mosquitto
 * @copyright Copyright (C) 2025 Southern California Edison
 */
#include "gapi_mosquitto.h"

volatile bool running = true;
volatile bool isConnected = false;
const int PORT = 1883;

int main(int argc, char **argv)
{
	if (argc < 4) {
		fprintf(stderr,
			"Usage:\n  %s sub <broker> <topic>\n  %s pub <broker> "
			"<topic> <message>\n",
			argv[0], argv[0]);
		return 1;
	}

	const char *mode = argv[1];
	const char *broker = argv[2];
	const char *topic = argv[3];
	const char *message = (argc >= 5) ? argv[4] : ""; // NOLINT: arguments
							  // limit number is not
							  // a magic number
	struct mosquitto *mosq = NULL;
	int port = PORT;
	int return_code = 0;

	mosq = api_communication_init(broker, port);
	if (!mosq) {
		return_code = EXIT_FAILURE;
		goto exit;
	}

	while (running && !isConnected) {
		mosquitto_loop(mosq, -1, 1);
		sleep(1);
	}

	if (strcmp(mode, "sub") == 0) {
		return_code = api_subscribe(mosq, topic);
		if (return_code) {
			goto disconnect;
		}

		fprintf(stdout,
			"Subscribed to %s on %s — waiting for messages...\n",
			topic, broker);

	} else if (strcmp(mode, "pub") == 0) {
		return_code = api_publish(mosq, topic, message);
		if (return_code) {
			goto disconnect;
		}

		fprintf(stdout, "Published to %s on %s: %s\n", topic, broker,
			message);
	} else {
		fprintf(stderr, "Unknown mode: %s\n", mode);
		running = false;
		return_code = EXIT_FAILURE;
	}

	while (running) {
		mosquitto_loop(mosq, -1, 1);
		sleep(1);
	}

disconnect:
	api_communication_deinit(mosq);
exit:
	return return_code;
}
