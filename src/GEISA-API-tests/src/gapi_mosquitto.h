/**
 * @file gapi_mosquitto.h
 * @brief Header file for GEISA MQTT communication using the Mosquitto library
 * @copyright Copyright (C) 2025 Southern California Edison
 */

#ifndef GAPI_MOSQUITTO_H
#define GAPI_MOSQUITTO_H

#include <mosquitto.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/**
 * @brief Global variable to control the running state of the MQTT client
 */
extern volatile bool running;

/**
 * @brief Global variable to control the request-response loop of the MQTT
 * client
 */
extern volatile bool rr_disconnect;

/**
 * @brief Global variable to indicate the connection state of the MQTT client
 */
extern volatile bool isConnected;

/**
 * @brief Initialize MQTT communication
 * This function is reading the mqtt configuration file to get the MQTT broker
 * address, port, package ID, and package token. It then initializes the
 * Mosquitto library and creates a new MQTT client instance.
 *
 * @return A pointer to the initialized mosquitto struct
 */
struct mosquitto *api_communication_init();

/**
 * @brief Deinitialize MQTT communication and clean up resources
 *
 * @param mosq Pointer to the mosquitto struct to be cleaned up
 */
void api_communication_deinit(struct mosquitto *mosq);

/**
 * @brief Subscribe to a specified MQTT topic
 *
 * @param mosq Pointer to the mosquitto struct
 * @param topic The MQTT topic to subscribe to
 * @param qos The Quality of Service level for the subscription (0, 1, or 2)
 * @return 0 on success, non-zero on failure
 */
int api_subscribe(struct mosquitto *mosq, const char *topic, int qos);

/**
 * @brief Publish a message to a specified MQTT topic
 *
 * @param mosq Pointer to the mosquitto struct
 * @param topic The MQTT topic to publish to
 * @param message_size The size of the message to publish
 * @param message The message to publish
 * @param qos The Quality of Service level for the message (0, 1, or 2)
 * @return 0 on success, non-zero on failure
 */
int api_publish(struct mosquitto *mosq, const char *topic, size_t message_size,
		const uint8_t *message, int qos);

#define MQTT_CONFIG_FIELD_SIZE 128

/**
 * @brief Structure to hold MQTT configuration parameters
 */
typedef struct {
	char mqtt_host[MQTT_CONFIG_FIELD_SIZE];
	int mqtt_port;
	char mqtt_id[MQTT_CONFIG_FIELD_SIZE];
	char mqtt_password[MQTT_CONFIG_FIELD_SIZE];
} mqtt_config;

/**
 * @brief Send a request message and wait for a response on a specified topic
 *
 * @param mosq Pointer to the mosquitto struct
 * @param request_topic The MQTT topic to send the request to
 * @param message_size The size of the request message to send
 * @param message The request message to send
 * @param response_topic The MQTT topic to listen for the response
 * @param qos The Quality of Service level for the request message (0, 1, or 2)
 * @return 0 on success, non-zero on failure
 */
int api_request_response(struct mosquitto *mosq, const char *request_topic,
			 size_t message_size, const uint8_t *message,
			 const char *response_topic, int qos);

#endif // GAPI_MOSQUITTO_H
