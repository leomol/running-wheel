/*
 * @file Wheel.ino
 * @brief Wheel firmware
 * @author Leonardo Molina
 * @see release-notes in https://github.com/leomol/running-wheel
 * @since 2019-04-27
 * @version 0.1.2207051500
*/

#include <Servo.h>
#include <SoftwareSerial.h>
#if defined(__AVR_ATmega2560__)
	const bool mega = true;
#else
	const bool mega = false;
#endif

// Locking and wheel id settings.
const uint8_t wheelId = 2;						// Wheel id, should be unique for each wheel.
const uint8_t openedAngle = 30;					// Wheel unlocks at this angle.
const int8_t closedAngle = 0;					// Wheel locks at this angle.

// Hardware pin-out settings.
const uint8_t servoPin = 9;						// Servo's data pin.
const uint8_t rfidRX = mega ? 10 : 4;			// Pin connected to TX of RFID reader. Mega2560: 10-13|50-53|A8-A15
const uint8_t rfidTX = 5;						// Pin connected to RX of RFID reader.
const uint8_t hallPins[] = {2, 3, 6};			// Hall sensor pins. Must preserve order.
const uint8_t tempPin = A3;						// Temperature pin.

// Behavior and communication settings.
const uint8_t nSync = 10;						// Handshake signal.
const uint8_t nHallSensors = sizeof(hallPins);	// Number of configured hall sensors.
const uint32_t servoSetupDuration = 100;		// Pause before engaging the servo.
const uint32_t servoEngageDuration = 100;		// Duration for which the servo is engaged.
const uint32_t temperatureInterval = 5000;		// Average/report temperature at regular intervals (ms).
const uint32_t servoInterval = 100;				// Duration the servo is engaged (ms).
const uint32_t pingInterval = 100;				// Interval of the alive message.
const uint32_t baudrate = 38400;				// Baudrate of serial communication with the PC.

// State variables.
bool debug = false;								// Debug mode prints plain text. Updates automatically according to input.
uint32_t pingTicker = 0;
uint32_t servoTicker = 0;
uint32_t temperatureTicker = 0;
uint32_t averageTemperature = 0;
uint16_t nTemperatureSamples = 0;
int16_t temperature = 0;
int8_t hallId = 0xFF;
uint8_t hallStates[3];
uint8_t tag[20] = {0};
uint8_t tagSize = 0;
bool ledState = LOW;
bool servoOpened = true;

enum class ServoStates {
	Setup,
	Engage,
	Disengage
};

ServoStates servoState;
SoftwareSerial serial(rfidRX, rfidTX);
Servo servo;

void setup() {
	// Start serial communication with PC and RFID reader.
	Serial.begin(baudrate);
	serial.begin(9600);
	
	// Set servo to default state.
	setServo(servoOpened);
	
	// Configure hall effect sensors.
	for (int id = 0; id < nHallSensors; id++)
		pinMode(hallPins[id], INPUT);
	getRotation();
	pinMode(LED_BUILTIN, OUTPUT);
}

void loop() {
	// Send ping message at regular intervals.
	if (millis() - pingTicker > pingInterval) {
		pingTicker = millis();
		ping();
	}
	
	// Compute and report rotation from hall effect sensors.
	int8_t step = getRotation();
	if (step)
		reportStep(step > 0 ? 1 : 0);
	
	// Update servo state.
	switch (servoState) {
		case ServoStates::Setup:
			if (millis() - servoTicker >= servoSetupDuration) {
				servoTicker = millis();
				servoState = ServoStates::Engage;
				servo.write(servoOpened ? openedAngle : closedAngle);
			}
			break;
		case ServoStates::Engage:
			if (millis() - servoTicker >= servoEngageDuration) {
				servo.detach();
				servoState = ServoStates::Disengage;
			}
			break;
	}
	
	// Measure temperature only when servo is disengaged.
	uint16_t currentTemperature = analogRead(tempPin);
	averageTemperature += currentTemperature;
	nTemperatureSamples += 1;
	if (millis() - temperatureTicker > temperatureInterval) {
		temperature = averageTemperature / nTemperatureSamples;
		reportTemperature(temperature);
		averageTemperature = 0;
		nTemperatureSamples = 0;
		temperatureTicker = millis();
	}
	
	// Parse data from RFID reader.
	while (serial.available() > 0) {
		// Data format: 2, a, b, ..., 10, 13, 3
		char input = serial.peek();
		if (input == 2) { // STX.
			serial.read();
			tagSize = 0;
		} else if (input == 3) { // ETX.
			tagSize -= 2; // Do not include 10 and 13
			serial.read();
			reportTag();
		} else {
			tag[tagSize++] = serial.read();
		}
	}
	
	// Parse data from PC.
	while (Serial.available()) {
		uint8_t command = Serial.read();
		switch (command) {
			case 0:
			case 1:
				setServo(command == 1);
				debug = false;
				break;
			case 255:
				for (int i = 0; i < nSync; i++)
					Serial.write(255);
				Serial.write(5);
				Serial.write(wheelId);
				debug = false;
				break;
			case '0':
			case '1':
				Serial.println(String() + "Servo: " + command);
				setServo(command == '1');
				debug = true;
				break;
			case '!':
				Serial.println(String() + "Synchronized!");
				Serial.println(String() + "Wheel id: " + wheelId);
				debug = true;
				break;
			default:
				Serial.println(String() + "echo: " + command);
				break;
		}
	}
}

void setServo(bool open) {
	servoOpened = open;
	servo.attach(servoPin);
	servoTicker = millis();
	servoState = ServoStates::Setup;
}

int8_t getRotation() {
	int8_t step = 0;
	bool changed = false;
	for (int8_t id = 0; id < nHallSensors; id++) {
		bool state = !digitalRead(hallPins[id]);
		if (hallStates[id] != state) {
			hallStates[id] = state;
			changed = true;
		}
		if (hallId != id && hallStates[id]) {
			step += (abs(hallId - id) + 1 == nHallSensors) ? (id == 0 ? +1 : -1) : (id > hallId ? +1 : -1);
			hallId = id;
		}
	}
	if (debug && changed)
		Serial.println(String() + "Temperature: " + temperature + " Rotation: " + hallStates[0] + ":" + hallStates[1] + ":" + hallStates[2] + " " + (step ? (step > 0 ? "+" : "-") : "="));
	return step;
}

void reportStep(bool increased) {
	if (!debug) {
		Serial.write(0);
		Serial.write(increased);
	}
}

void reportTemperature(int16_t temperature) {
	if (!debug) {
		Serial.write(1);
		Serial.write((uint8_t) (temperature >> 0 & 0xFF));
		Serial.write((uint8_t) (temperature >> 8 & 0xFF));
	}
}

void reportTag() {
	char const hex[16] = {'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F'};
	if (debug) {
		Serial.print(String() + "Tag: ");
		for (int i = 0; i < tagSize; i++) {
			Serial.print(hex[(tag[i] & 0xF0) >> 4]);
			Serial.print(hex[(tag[i] & 0x0F) >> 0]);
		}
		Serial.println();
	} else {
		Serial.write(2);
		for (int i = 0; i < tagSize; i++)
			Serial.write(tag[i]);
		Serial.write(3);
	}
}

void ping() {
	ledState = !ledState;
	digitalWrite(LED_BUILTIN, ledState);
	if (!debug) {
		Serial.write(4);
		Serial.write(servoOpened);
	}
}