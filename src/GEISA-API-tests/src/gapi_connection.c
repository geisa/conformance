/**
 * @file gapi_connection.c
 * @brief Test connection and deconnection of the MQTT broker
 * @copyright Copyright (C) 2025 Southern California Edison
 */
#include "gapi_mosquitto.h"

volatile bool running = true;
volatile bool isConnected = false;

int main()
{
	struct mosquitto *mosq = NULL;

	mosq = api_communication_init();
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
