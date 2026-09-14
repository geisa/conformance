Application Isolation
=====================

Applications SHALL not run as root.

Platform implementations MUST provide:

- a shared base image

  - a hardened base image
- application image support

Networking
----------

Applications MUST be denied direct network access by default.

- /tmp

  - MUST be limited in size as described in the deployment manifest

    - a constrained temporary directory

Applications may use another library, otherwise they must bring their own.

Platform implementations MUST retain application state and SHALL NOT discard it
before a requested reset.

- application data
- runtime state
