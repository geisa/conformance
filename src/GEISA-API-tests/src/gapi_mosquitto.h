/**
 * @file gapi_mosquitto.h
 * @brief Header file for GEISA MQTT communication using the Mosquitto library
 * @copyright Copyright (C) 2025 Southern California Edison
 */

#ifndef GAPI_MOSQUITTO_H
#define GAPI_MOSQUITTO_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mosquitto.h>
#include <signal.h>
#include <unistd.h>

/**
 * @brief Global variable to control the running state of the MQTT client
 */
extern volatile bool running;

/**
 * @brief Global variable to indicate the connection state of the MQTT client
 */
extern volatile bool isConnected;

/**
 * @brief Initialize MQTT communication with the specified broker and port
 * 
 * @param broker The MQTT broker address
 * @param port The MQTT broker port
 * @return A pointer to the initialized mosquitto struct
 */
struct mosquitto * api_communication_init(const char *broker, int port);

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
 * @return 0 on success, non-zero on failure
 */
int api_subscribe(struct mosquitto *mosq, const char *topic);

/**
 * @brief Publish a message to a specified MQTT topic
 *
 * @param mosq Pointer to the mosquitto struct
 * @param topic The MQTT topic to publish to
 * @param message The message to publish
 * @return 0 on success, non-zero on failure
 */
int api_publish(struct mosquitto *mosq, const char *topic, const char *message);

#endif // GAPI_MOSQUITTO_H
