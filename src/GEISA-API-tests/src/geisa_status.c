/**
 * @file geisa_status.c
 * @brief Shared helpers for validating GEISA response status objects
 * @copyright Copyright (C) 2026 Southern California Edison
 */

#include "geisa_status.h"
#include <stdio.h>
#include <stdlib.h>

int check_geisa_status(const GeisaStatus *status, const char *api_name)
{
	int ret = EXIT_SUCCESS;

	if (status->code != GeisaStatusCode_GEISA_STATUS_SUCCESS) {
		fprintf(stderr, "[%s] Error: response not success\n", api_name);
		ret = EXIT_FAILURE;
	}

	if (!status->message || !status->message[0]) {
		fprintf(
		    stderr,
		    "[%s] Error: response missing status message information\n",
		    api_name);
		ret = EXIT_FAILURE;
	}

	return ret;
}
