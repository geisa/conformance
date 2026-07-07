/**
 * @file geisa_status.h
 * @brief Shared helpers for validating GEISA response status objects
 * @copyright Copyright (C) 2026 Southern California Edison
 */

#ifndef GEISA_STATUS_H
#define GEISA_STATUS_H

#include "schemas/geisa-status.pb.h"

/**
 * @brief Validate a GEISA response status.
 *
 * @param status Pointer to the status object to validate
 * @param api_name Short API label used in error messages
 * @return EXIT_SUCCESS if the status is valid, EXIT_FAILURE otherwise
 */
int check_geisa_status(const GeisaStatus *status, const char *api_name);

#endif // GEISA_STATUS_H
