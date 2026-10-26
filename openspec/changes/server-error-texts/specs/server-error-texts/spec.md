## ADDED Requirements

### Requirement: Failed requests show the server's message
When a request to the server fails with an HTTP error, the system SHALL show the server's message, taken in the order the official clients use: the first validation error, else the message, else the identity error model's message. A rate limit response (HTTP 429) SHALL show "Rate limit exceeded. Try again later.". When the response has no such message, the system SHALL show "Server error <code>.". The raw response body SHALL NOT be shown.

#### Scenario: Vaultwarden validation error
- **GIVEN** the server answers 400 with `{"message":"Folder name too long","validationErrors":{"":["Folder name too long"]},"object":"error"}`
- **WHEN** the error is shown
- **THEN** the text SHALL be "Folder name too long"

#### Scenario: HTML error page from a proxy
- **GIVEN** a proxy answers 502 with an HTML page
- **WHEN** the error is shown
- **THEN** the text SHALL be "Server error 502."

### Requirement: Public logs never contain error messages or response bodies
Every log entry that records an error with public visibility SHALL describe it only by HTTP status, URL error code, or error type and case. It SHALL NOT contain the error's message, a response body, or user data.

#### Scenario: Sync fails with a server error
- **GIVEN** the sync request fails with 500 and a body that contains an e-mail address
- **WHEN** the failure is logged
- **THEN** the public log entry SHALL contain "HTTP 500" and SHALL NOT contain the body
