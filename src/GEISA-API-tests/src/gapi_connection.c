/**
 * @file gapi_connection.c
 * @brief Test connection and deconnection of the MQTT broker
 * @copyright Copyright (C) 2025 Southern California Edison
 */
#include "gapi_mosquitto.h"

volatile bool running = true;
volatile bool isConnected = false;
#define PORT 1883

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "Usage:\n  %s <broker>\n", argv[0]);
		return 1;
	}

	const char *broker = argv[1];
	struct mosquitto *mosq = NULL;
	int port = PORT;

	mosq = api_communication_init(broker, port);
	if (!mosq) {
		return EXIT_FAILURE;
	}

	while (running && !isConnected) {
		mosquitto_loop(mosq, -1, 1);
		sleep(1);
	}

	api_communication_deinit(mosq);
	return EXIT_SUCCESS;
}
