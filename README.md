# Running wheel
Control program for a custom made running wheel with a locking mechanism.
![Running Wheel - GUI](etc/running-wheel-ui.png)

## Prerequisites
* [Wheel Control][Installer] to install the control program.
* [Arduino IDE][Arduino] to upload the firmware to the micro-controller of the wheel (last compiled and tested with Arduino 1.8.5).
* [MATLAB][MATLAB] only if planning on editing the source code (last tested with R2019a).

## Install control program
* Download and install [Wheel Control][Installer].
* Download and install [Arduino][Arduino].

## Flash wheel firmware
* Connect one or more wheels to the computer
* Open `Wheel.ino` with Arduino IDE, edit the value of `wheelId` so that each wheel has a unique number
* Set `Tools/Board` to `Arduino Pro or Pro Mini"` and `Tools/Processor` to `ATmega328p (3V, 8MHz)` or `ATmega328p (5V, 15MHz)` according to the choice of micro-controller for your apparatus
* Set one port at a time in `Tools/Port` and click `Sketch/Upload`
* You may need to install [FTDI drivers](https://learn.sparkfun.com/tutorials/how-to-install-ftdi-drivers/all) first.

If planning on editing the source code:
* Download and install [MATLAB][MATLAB].
* Download and extract the [source code][Source Code] to Documents/MATLAB

## Control program overview
* Open the control program by going to `Start Menu / Wheel`
* Connect one or several wheels; a temperature trace will be plotted shortly after each connection is stablished.
* The RFID tag list is populated when an animal gets on the wheel or if you write a list of RFID tags to set a target running distance. This locking distance is also listed next to each tag.
* A distance trace will be plotted for each animal (i.e. each RFID tag).

## Setting the locking distance
The locking mechanism engages whenever the apparatus detects that an animal with a given RFID tag reaches a previously defined locking distance and disengages for other animals or if the locking distance is extended for the animal on the wheel.

The target distance can be applied immediately or scheduled to happen at a given time of the day, and defined separately for each animal or a group of animals.

* Select one or more tags from the tag list or type these directly in the text box
* Type a distance value in centimeters
* Click `set` to apply a locking distance relative to 0; or
* Click `add` to apply a locking distance relative to the current distance; or
* Click `schedule` and set a date when prompted in the format HHMMSS (2-digit hour, 2-digit minute, 2-digit second) to apply a locking distance relative to the current distance at a given time of the day
* Repeat if necessary for different subset of animals or different distance values

## Data logs
Data from each wheel are displayed in the GUI and saved as soon as they are received into a comma-separated-values file (CSV file) with a name corresponding to the RFID tag, under the folder Documents/Wheel. These data consist of cage id, cage temperature, wheel rotation, and the animal's RFID tag.

This csv file can be opened as a Spreadsheet in Excel for a quick review or imported into MATLAB for more advanced manipulations.

## Version History
See [release notes][Release Notes]

## License
© 2019 [Leonardo Molina][Leonardo Molina]

This project is licensed under the [GNU GPLv3 License][License].

[Leonardo Molina]: https://github.com/leomol
[Arduino]: https://www.arduino.cc/en/Main/Software
[Installer]: bin/wheel-installer.exe
[MATLAB]: https://www.mathworks.com/downloads/
[License]: LICENSE.md
[Source Code]: https://github.com/leomol/running-wheel/archive/master.zip
[Release Notes]: release-notes.md
