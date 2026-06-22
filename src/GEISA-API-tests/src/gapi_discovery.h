/**
 * @file gapi_discovery.h
 * @brief Header file for API platform discovery messages
 * @copyright Copyright (C) 2026 Southern California Edison
 */

#ifndef GAPI_DISCOVERY_H
#define GAPI_DISCOVERY_H

#include "gapi_mosquitto.h"
#include "schemas/discovery.pb.h"

/**
 * @brief Send a discovery request message to the MQTT broker
 *
 * @param mosq Pointer to the Mosquitto client instance
 * @return 0 on success, non-zero on failure
 */
int send_discovery_request(struct mosquitto *mosq);

#endif // GAPI_DISCOVERY_H
