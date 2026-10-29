# Spec Delta

## MODIFIED Requirements

### Requirement: Failed requests show the server's message
When a request to the server fails with an HTTP error, the system SHALL show the server's message, taken in the order the official clients use: the first validation error, else the message, else the identity error model's message. A rate limit response (HTTP 429) SHALL show "Rate limit exceeded. Try again later.". When the response has no such message, the system SHALL show "Server error <code>.". The raw response body SHALL NOT be shown. An out-of-date update SHALL show the conflict message.

#### Scenario: Vaultwarden validation error
- **GIVEN** the server answers 400 with `{"message":"Folder name too long","validationErrors":{"":["Folder name too long"]},"object":"error"}`
- **WHEN** the error is shown
- **THEN** the text SHALL be "Folder name too long"

#### Scenario: HTML error page from a proxy
- **GIVEN** a proxy answers 502 with an HTML page
- **WHEN** the error is shown
- **THEN** the text SHALL be "Server error 502."

#### Scenario: Out-of-date item update
- **GIVEN** the server answers an item update with 400 and the message "The client copy of this cipher is out of date. Resync the client and try again."
- **WHEN** the error is shown
- **THEN** the text SHALL be the conflict message, not the server's message
