/**
 * @file gapi_connection.c
 * @brief Test connection and deconnection of the MQTT broker
 * @copyright Copyright (C) 2025 Southern California Edison
 */
#include "gapi_mosquitto.h"

volatile bool running = true;
volatile bool isConnected = false;
volatile bool rr_disconnect = false;

/**
 * @brief Main function for the connection API test. It initializes the MQTT
 * client, attempts to connect to the broker, and then deinitializes the client.
 *
 * @return EXIT_SUCCESS if the connection and disconnection were successful,
 * otherwise EXIT_FAILURE.
 */
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

	if (!isConnected) {
		fprintf(stderr, "Failed to connect to broker\n");
		api_communication_deinit(mosq);
		return EXIT_FAILURE;
	}

	api_communication_deinit(mosq);
	return EXIT_SUCCESS;
}
