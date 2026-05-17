#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <WebSocketsClient.h>
#include <ArduinoJson.h>
#include <Preferences.h>

// -----------------------------
// Hardware pins (update as needed)
// -----------------------------
#define IN1 25  // Left motor input 1
#define IN2 26  // Left motor input 2
#define IN3 27  // Right motor input 1
#define IN4 14  // Right motor input 2

// -----------------------------
// AP mode config
// -----------------------------
static const char* AP_SSID = "GISMO_AP";

// -----------------------------
// Backend config
// -----------------------------
static const char* WS_HOST = "gismo-app-backend-production.up.railway.app";
static const uint16_t WS_PORT = 443;
static const char* API_KEY = "24232423";
static const char* DEFAULT_ROBOT_ID = "00000000-0000-0000-0000-000000000001";

// -----------------------------
// Timing config
// -----------------------------
static const unsigned long STATUS_INTERVAL_MS = 2000;
static const unsigned long WIFI_CONNECT_TIMEOUT_MS = 15000;
static const unsigned long WIFI_RETRY_INTERVAL_MS = 5000;
static const uint8_t WIFI_MAX_RETRIES_BEFORE_AP = 6;

enum DeviceMode {
  MODE_AP,
  MODE_STA
};

WebServer server(80);
WebSocketsClient webSocket;
Preferences preferences;
DeviceMode currentMode = MODE_AP;

String savedSsid;
String savedPass;
String savedRobotId;
String savedRobotName;

unsigned long lastStatusAt = 0;
unsigned long lastWiFiRetryAt = 0;
uint8_t wifiRetryCount = 0;
bool wsConnected = false;

// -----------------------------
// Motor control
// -----------------------------
void stopMotors() {
  digitalWrite(IN1, LOW);
  digitalWrite(IN2, LOW);
  digitalWrite(IN3, LOW);
  digitalWrite(IN4, LOW);
}

void moveForward() {
  digitalWrite(IN1, HIGH);
  digitalWrite(IN2, LOW);
  digitalWrite(IN3, HIGH);
  digitalWrite(IN4, LOW);
}

void moveBackward() {
  digitalWrite(IN1, LOW);
  digitalWrite(IN2, HIGH);
  digitalWrite(IN3, LOW);
  digitalWrite(IN4, HIGH);
}

void turnLeft() {
  digitalWrite(IN1, LOW);
  digitalWrite(IN2, HIGH);
  digitalWrite(IN3, HIGH);
  digitalWrite(IN4, LOW);
}

void turnRight() {
  digitalWrite(IN1, HIGH);
  digitalWrite(IN2, LOW);
  digitalWrite(IN3, LOW);
  digitalWrite(IN4, HIGH);
}

void driveMotors(char command) {
  Serial.print("Driving motors with command: ");
  Serial.println(command);

  switch (command) {
    case 'F':
      moveForward();
      break;
    case 'B':
      moveBackward();
      break;
    case 'L':
      turnLeft();
      break;
    case 'R':
      turnRight();
      break;
    case 'S':
    default:
      stopMotors();
      break;
  }
}

// -----------------------------
// WebSocket control channel
// -----------------------------
String webSocketPath() {
  String robotId = savedRobotId.isEmpty() ? DEFAULT_ROBOT_ID : savedRobotId;
  robotId.toLowerCase();

  String path = "/ws?role=robot&robot_id=";
  path += robotId;
  path += "&api_key=";
  path += API_KEY;
  return path;
}

void sendWebSocketJson(const JsonDocument& doc) {
  if (!wsConnected) {
    return;
  }

  String payload;
  serializeJson(doc, payload);
  webSocket.sendTXT(payload);
}

void sendStatus(bool online = true) {
  DynamicJsonDocument doc(256);
  doc["type"] = "status";
  doc["is_online"] = online;
  doc["last_ip"] = WiFi.status() == WL_CONNECTED ? WiFi.localIP().toString() : "";
  sendWebSocketJson(doc);
}

void acknowledgeCommand(const char* commandId) {
  if (commandId == nullptr || strlen(commandId) == 0) {
    return;
  }

  DynamicJsonDocument doc(256);
  doc["type"] = "command_done";
  doc["command_id"] = commandId;
  sendWebSocketJson(doc);
}

void acknowledgeCommand(int commandId) {
  if (commandId <= 0) {
    return;
  }

  DynamicJsonDocument doc(256);
  doc["type"] = "command_done";
  doc["command_id"] = commandId;
  sendWebSocketJson(doc);
}

void clearProvisioningData() {
  preferences.begin("wifi", false);
  preferences.clear();
  preferences.end();

  savedSsid = "";
  savedPass = "";
  savedRobotId = DEFAULT_ROBOT_ID;
  savedRobotName = "Gismo";
}

void restartInApMode() {
  Serial.println("Reset WiFi command received. Clearing credentials and restarting into AP mode.");
  stopMotors();
  clearProvisioningData();
  delay(300);
  ESP.restart();
}

void handleCommandMessage(JsonDocument& doc) {
  String cmdText = doc["command"] | "";
  if (cmdText.length() == 0) {
    Serial.println("Command message ignored: missing command field");
    return;
  }

  Serial.print("Command received: ");
  Serial.println(cmdText);

  if (cmdText == "A" || cmdText == "RESET_WIFI") {
    if (doc["id"].is<int>()) {
      acknowledgeCommand(doc["id"].as<int>());
    } else {
      const char* commandId = doc["id"] | "";
      acknowledgeCommand(commandId);
    }
    restartInApMode();
    return;
  }

  driveMotors(cmdText.charAt(0));

  if (doc["id"].is<int>()) {
    acknowledgeCommand(doc["id"].as<int>());
  } else {
    const char* commandId = doc["id"] | "";
    acknowledgeCommand(commandId);
  }
}

void handleWebSocketMessage(uint8_t* payload, size_t length) {
  Serial.print("WS raw message: ");
  Serial.write(payload, length);
  Serial.println();

  DynamicJsonDocument doc(1024);
  DeserializationError err = deserializeJson(doc, payload, length);
  if (err) {
    Serial.print("WS JSON parse error: ");
    Serial.println(err.c_str());
    return;
  }

  String type = doc["type"] | "";
  Serial.print("WS message type: ");
  Serial.println(type);

  if (type == "connected") {
    sendStatus(true);
    return;
  }

  if (type == "command" || doc["command"].is<const char*>() || doc["command"].is<String>()) {
    handleCommandMessage(doc);
    return;
  }

  if (type == "ping") {
    DynamicJsonDocument pong(128);
    pong["type"] = "pong";
    if (doc["request_id"].is<const char*>()) {
      pong["request_id"] = doc["request_id"].as<const char*>();
    }
    sendWebSocketJson(pong);
    return;
  }

  if (type == "error") {
    Serial.print("WS server error: ");
    Serial.println(doc["message"] | "unknown");
    return;
  }

  Serial.print("Unhandled WS message type: ");
  Serial.println(type);
}

void onWebSocketEvent(WStype_t type, uint8_t* payload, size_t length) {
  switch (type) {
    case WStype_CONNECTED:
      wsConnected = true;
      Serial.println("WebSocket connected");
      sendStatus(true);
      break;

    case WStype_DISCONNECTED:
      wsConnected = false;
      stopMotors();
      Serial.println("WebSocket disconnected");
      break;

    case WStype_TEXT:
      handleWebSocketMessage(payload, length);
      break;

    case WStype_ERROR:
      wsConnected = false;
      stopMotors();
      Serial.print("WebSocket error");
      if (length > 0) {
        Serial.print(": ");
        Serial.write(payload, length);
      }
      Serial.println();
      break;

    default:
      break;
  }
}

void startWebSocket() {
  wsConnected = false;
  String path = webSocketPath();
  Serial.print("Robot ID: ");
  Serial.println(savedRobotId);
  Serial.print("Connecting WebSocket: wss://");
  Serial.print(WS_HOST);
  Serial.println(path);
  webSocket.beginSSL(WS_HOST, WS_PORT, path.c_str());
  webSocket.onEvent(onWebSocketEvent);
  webSocket.setReconnectInterval(3000);
  webSocket.enableHeartbeat(15000, 3000, 2);
}

void stopWebSocket() {
  wsConnected = false;
  webSocket.disconnect();
}

// -----------------------------
// Helpers
// -----------------------------
void addCommonHeaders() {
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.sendHeader("Access-Control-Allow-Methods", "GET,POST,PUT,OPTIONS");
  server.sendHeader("Access-Control-Allow-Headers", "Content-Type");
}

void sendJsonResponse(int statusCode, const String& payload) {
  addCommonHeaders();
  server.send(statusCode, "application/json", payload);
}

void loadWiFiCredentials() {
  preferences.begin("wifi", true);
  savedSsid = preferences.getString("ssid", "");
  savedPass = preferences.getString("pass", "");
  savedRobotId = preferences.getString("robot_id", DEFAULT_ROBOT_ID);
  savedRobotName = preferences.getString("robot_name", "Gismo");
  preferences.end();
}

void saveProvisioningData(const String& ssid, const String& pass, const String& robotId, const String& robotName) {
  String normalizedRobotId = robotId;
  normalizedRobotId.toLowerCase();

  preferences.begin("wifi", false);
  preferences.putString("ssid", ssid);
  preferences.putString("pass", pass);
  preferences.putString("robot_id", normalizedRobotId);
  preferences.putString("robot_name", robotName);
  preferences.end();
}

bool connectToSavedWiFi(unsigned long timeoutMs = WIFI_CONNECT_TIMEOUT_MS) {
  if (savedSsid.isEmpty()) {
    return false;
  }

  WiFi.mode(WIFI_STA);
  WiFi.begin(savedSsid.c_str(), savedPass.c_str());

  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < timeoutMs) {
    delay(250);
  }

  if (WiFi.status() == WL_CONNECTED) {
    wifiRetryCount = 0;
    lastWiFiRetryAt = millis();
    return true;
  }

  return false;
}

void configureApRoutes() {
  server.on("/scan", HTTP_GET, []() {
    int n = WiFi.scanNetworks();
    DynamicJsonDocument doc(2048);
    JsonArray arr = doc.to<JsonArray>();

    for (int i = 0; i < n; i++) {
      JsonObject ap = arr.createNestedObject();
      ap["ssid"] = WiFi.SSID(i);
      ap["rssi"] = WiFi.RSSI(i);
      ap["auth"] = static_cast<int>(WiFi.encryptionType(i));
    }

    String out;
    serializeJson(arr, out);
    sendJsonResponse(200, out);
  });

  server.on("/connect", HTTP_POST, []() {
    if (!server.hasArg("plain")) {
      sendJsonResponse(400, "{\"success\":false,\"message\":\"Missing JSON body\"}");
      return;
    }

    DynamicJsonDocument doc(512);
    DeserializationError err = deserializeJson(doc, server.arg("plain"));
    if (err) {
      sendJsonResponse(400, "{\"success\":false,\"message\":\"Invalid JSON\"}");
      return;
    }

    String ssid = doc["ssid"] | "";
    String pass = doc["pass"] | "";
    String robotId = doc["robot_id"] | "";
    String robotName = doc["robot_name"] | "Gismo";

    if (ssid.isEmpty()) {
      sendJsonResponse(400, "{\"success\":false,\"message\":\"SSID is required\"}");
      return;
    }

    if (robotId.isEmpty()) {
      sendJsonResponse(400, "{\"success\":false,\"message\":\"robot_id is required\"}");
      return;
    }

    saveProvisioningData(ssid, pass, robotId, robotName);
    sendJsonResponse(200, "{\"success\":true,\"message\":\"Credentials saved, restarting\"}");
    delay(400);
    ESP.restart();
  });

  server.on("/status", HTTP_GET, []() {
    DynamicJsonDocument doc(256);
    bool connected = WiFi.status() == WL_CONNECTED;
    doc["connected"] = connected;
    doc["mode"] = currentMode == MODE_AP ? "ap" : "sta";
    doc["websocket_connected"] = wsConnected;
    doc["robot_id"] = savedRobotId;
    doc["robot_name"] = savedRobotName;
    doc["ip"] = connected ? WiFi.localIP().toString() : "";
    doc["ssid"] = connected ? WiFi.SSID() : "";

    String out;
    serializeJson(doc, out);
    sendJsonResponse(200, out);
  });

  server.onNotFound([]() {
    sendJsonResponse(404, "{\"success\":false,\"message\":\"Not found\"}");
  });
}

void startApMode() {
  stopMotors();
  stopWebSocket();
  WiFi.mode(WIFI_AP);
  WiFi.softAP(AP_SSID);

  server.stop();
  configureApRoutes();
  server.begin();

  currentMode = MODE_AP;
}

void startStaMode() {
  WiFi.softAPdisconnect(true);
  WiFi.mode(WIFI_STA);

  server.stop();

  lastStatusAt = 0;
  lastWiFiRetryAt = millis();
  wifiRetryCount = 0;
  startWebSocket();

  currentMode = MODE_STA;
}

void sendPeriodicStatus() {
  if (millis() - lastStatusAt < STATUS_INTERVAL_MS) {
    return;
  }
  lastStatusAt = millis();
  sendStatus(true);
}

void handleStaConnectivity() {
  if (WiFi.status() == WL_CONNECTED) {
    wifiRetryCount = 0;
    return;
  }

  if (millis() - lastWiFiRetryAt < WIFI_RETRY_INTERVAL_MS) {
    return;
  }

  lastWiFiRetryAt = millis();
  wifiRetryCount++;
  wsConnected = false;
  stopMotors();
  WiFi.reconnect();

  if (wifiRetryCount >= WIFI_MAX_RETRIES_BEFORE_AP) {
    startApMode();
  }
}

void setupWiFi() {
  loadWiFiCredentials();

  if (connectToSavedWiFi()) {
    startStaMode();
  } else {
    startApMode();
  }
}

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println("GISMO firmware boot: websocket-control-v2");

  pinMode(IN1, OUTPUT);
  pinMode(IN2, OUTPUT);
  pinMode(IN3, OUTPUT);
  pinMode(IN4, OUTPUT);
  stopMotors();

  setupWiFi();
}

void loop() {
  if (currentMode == MODE_AP) {
    server.handleClient();
    delay(2);
    return;
  }

  handleStaConnectivity();

  if (currentMode == MODE_STA && WiFi.status() == WL_CONNECTED) {
    webSocket.loop();
    sendPeriodicStatus();
  }

  delay(2);
}
