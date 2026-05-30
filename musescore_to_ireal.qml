//=============================================================================
//  MuseScore to iReal Pro Export Plugin
//
//  Based in part on the MuseScore iRealPro plugin by Norman Schmidt.
//
//  Original code:
//  Copyright (c) 2017 Norman Schmidt
//
//  Modifications and additional functionality:
//  Copyright (c) 2026 Ilvis Faulbaums
//
//  Modified by Ilvis Faulbaums on 2026-05-31.
//  Changes include chord-grid export logic, MuseScore repeat-barline handling,
//  time-signature export, automatic volta detection, and iReal Pro output.
//
//  This program is free software; you can redistribute it and/or modify
//  it under the terms of the GNU General Public License version 2
//  as published by the Free Software Foundation.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License version 2 for more details.
//
//  You should have received a copy of the GNU General Public License
//  version 2 along with this program. If not, see
//  https://www.gnu.org/licenses/old-licenses/gpl-2.0.html.
//=============================================================================


import QtQuick 2.0
import MuseScore 3.0
import FileIO 3.0
import QtQuick.Dialogs 1.2

MuseScore {
    version: "3.1"
    description: "Harmony analyzer with MuseScore barline detection and iReal Pro output"
    menuPath: "export.ToiRealPro"
    requiresScore: true;
    QProcess {
         id: proc
     }
    // MuseScore 3 BarLineType values from the plugin API.
    property int barlineStartRepeat: 4
    property int barlineEndRepeat: 8
    property int barlineEndStartRepeat: 64
    // Drošības limits GUI navigācijai, kas atrod VoltaSegment objektus.
    property int maxVoltaNavigationSteps: 20000

function convertHarmony(symbol) {
  //  symbol = symbol.charAt(0)+ symbol.substr(1);
    symbol = symbol.replace('(', '');
    symbol = symbol.replace(')', '');
    symbol = symbol.replace('dim', 'o');
    symbol = symbol.replace('-7b5', 'h');
    symbol = symbol.replace('ø', 'h');
    symbol = symbol.replace('0', 'h');
    symbol = symbol.replace('m', '-');
    symbol = symbol.replace('N.C.', 'n');
    return symbol;
}


    function valueText(value) {
        if (value === undefined || value === null)
            return "undefined";
        return "" + value;
    }

    function isChordOrRest(element) {
        if (!element)
            return false;

        return element.type === Element.CHORD ||
               element.type === Element.REST ||
               element.name === "Chord" ||
               element.name === "Rest";
    }

    function isVoltaSegment(element) {
        if (!element)
            return false;

        return element.type === Element.VOLTA_SEGMENT ||
               element.name === "VoltaSegment";
    }

    function selectedElementKey(element) {
        if (!element)
            return "null";

        var key = valueText(element.name) + "|" +
                  valueText(element.type) + "|" +
                  valueText(element.volta_ending);

        if (element.pagePos) {
            key += "|" + valueText(element.pagePos.x) +
                   "|" + valueText(element.pagePos.y);
        }

        return key;
    }

    function findFirstNavigableElement() {
        var cursor = curScore.newCursor();

        for (var staff = 0; staff < curScore.nstaves; staff++) {
            for (var voice = 0; voice < 4; voice++) {
                cursor.staffIdx = staff;
                cursor.voice = voice;
                cursor.rewind(Cursor.SCORE_START);

                while (cursor.segment) {
                    if (cursor.element)
                        return cursor.element;
                    cursor.next();
                }
            }
        }

        return null;
    }

    /*
       MuseScore 3 neuzrāda voltas measure.elements vai segment.annotations,
       bet VoltaSegment ir sasniedzams ar cmd("next-element").
       Tavā pārbaudē VoltaSegment parādās uzreiz pēc šīs takts Rest/Chord,
       tādēļ N1/N2 tiek piesaistīts pēdējā apmeklētā Chord/Rest segmenta tick.
    */
    function collectVoltaTokensByMeasureTick() {
        var voltaTokens = {};
        var foundVoltas = {};
        var visitedElements = {};
        var firstElement = findFirstNavigableElement();

        if (!firstElement) {
            console.log("Voltu meklēšana: nav sākuma Chord/Rest elementa.");
            return voltaTokens;
        }

        var selectedOk = curScore.selection.select(firstElement, false);
        console.log("Voltu meklēšana: sākuma elements = " +
                    valueText(firstElement.name) +
                    ", select = " + valueText(selectedOk));

        var lastChordRestTick = -1;
        var previousKey = "";
        var unchangedCount = 0;

        for (var step = 0; step < maxVoltaNavigationSteps; step++) {
            var selectionElements = curScore.selection.elements;

            if (!selectionElements || selectionElements.length === 0)
                break;

            var selected = selectionElements[0];
            var currentKey = selectedElementKey(selected);

            if (currentKey === previousKey) {
                unchangedCount++;
                if (unchangedCount >= 5)
                    break;
            } else {
                unchangedCount = 0;
            }
            previousKey = currentKey;

            if (isChordOrRest(selected) &&
                selected.parent &&
                selected.parent.tick !== undefined) {
                lastChordRestTick = Number(selected.parent.tick);
            }

            if (isVoltaSegment(selected)) {
                var endingNumber = Number(selected.volta_ending);
                var token = "N" + endingNumber;
                var foundKey = token + "|" + lastChordRestTick;

                if (lastChordRestTick >= 0 &&
                    !isNaN(endingNumber) &&
                    foundVoltas[foundKey] !== true) {
                    foundVoltas[foundKey] = true;
                    voltaTokens["" + lastChordRestTick] = token;
                    console.log("Atrasta volta: " + token +
                                ", piesaistīta takts tick = " +
                                lastChordRestTick);
                }
            }

            if (visitedElements[currentKey] === true && step > 0)
                break;

            visitedElements[currentKey] = true;
            cmd("next-element");
        }

        return voltaTokens;
    }

    MessageDialog {
        id: successDialog
        title: "Success"
        text: "File successfully saved to Desktop/irealpro_chart.html"
        icon: StandardIcon.Information
        standardButtons: StandardButton.Ok
        visible: false
    }

    MessageDialog {
        id: errorDialog
        title: "Error"
        text: "Failed to save the file. Please ensure the directory exists."
        icon: StandardIcon.Critical
        standardButtons: StandardButton.Ok
        visible: false
    }

    FileIO {
        id: fileIO
        onError: console.log("FileIO Error:", msg)
    }

    onRun: {
        if (!curScore) {
            Qt.quit();
            return;
        }

        var iReal = "";
        var currentTimeSig = "4/4";
        // Pēdējais Harmony turpinās līdz nākamajam Harmony simbolam.
        // Tas atbilst "var akordi" piemēra ilgumu loģikai.
        var previousHarmonyText = "";
        var currentBarStartTick = 0;
        var currentBarTicks = division * 4;
        var measureText = "";

        // iReal Pro voltas marķieri: N1, N2, N3 pirms attiecīgās takts satura.
        var voltaTokensByMeasureTick = collectVoltaTokensByMeasureTick();

        // Helper functions for time signatures and beat positions.
        function beatTicksForTimeSignature(timeSig) {
            var parts = timeSig.match(/(\d+)\/(\d+)/);
            if (!parts)
                return division;

            var denominator = parseInt(parts[2]);
            return division * (4 / denominator);
        }

        function setCurrentTimeSignature(timeSig) {
            var parts = timeSig.match(/(\d+)\/(\d+)/);
            if (!parts)
                return;

            currentTimeSig = timeSig;
            var numerator = parseInt(parts[1]);
            currentBarTicks = beatTicksForTimeSignature(timeSig) * numerator;
        }

        // Reads the signature effective in this measure.
        // Uses the same MuseScore 3 detection approach as the BigTime plugin:
        // SegmentType.TimeSig == 0x10 and element.name == "TimeSig".
        // iReal places a T-token before the barline entering that measure.
        function getTimeSignatureTokenForMeasure(measure, forceOutput) {
            var signatureAtMeasure = currentTimeSig;
            var segment = measure.firstSegment;

            while (segment) {
                if (segment.segmentType == 0x10) { // SegmentType.TimeSig
                    for (var track = 0; track < curScore.ntracks; track++) {
                        var element = segment.elementAt(track);
                        if (element && element.name === "TimeSig") {
                            signatureAtMeasure = element.timesig.numerator + "/" +
                                                 element.timesig.denominator;
                            break;
                        }
                    }
                }
                segment = segment.nextInMeasure;
            }

            var changed = signatureAtMeasure !== currentTimeSig;
            setCurrentTimeSignature(signatureAtMeasure);

            if (forceOutput || changed)
                return "T" + signatureAtMeasure.replace("/", "");
            return "";
        }

        function insertBeforePreviousBoundary(token) {
            if (!token)
                return;

            var suffix = "";
            if (iReal.length >= 2 && iReal.substr(iReal.length - 2) === "}{") {
                suffix = "}{";
                iReal = iReal.substr(0, iReal.length - 2);
            } else if (iReal.length > 0) {
                var last = iReal.charAt(iReal.length - 1);
                if (last === "|" || last === "}" || last === "{") {
                    suffix = last;
                    iReal = iReal.substr(0, iReal.length - 1);
                }
            }

            iReal += "" + suffix + token;
        }

        // Find repeat barlines attached to a measure.
        // iReal Pro barline encoding:
        // START_REPEAT -> {
        // END_REPEAT -> }
        // END_START_REPEAT -> }{
        function getMeasureRepeats(measure) {
            var flags = { start: false, end: false, endStart: false };

            function inspectBarLine(element) {
                if (!element || element.type !== Element.BAR_LINE)
                    return;

                var barType = Number(element.barlineType);
                if (barType === barlineStartRepeat)
                    flags.start = true;
                else if (barType === barlineEndRepeat)
                    flags.end = true;
                else if (barType === barlineEndStartRepeat)
                    flags.endStart = true;
            }

            // Barlines are normally available in measure segments.
            var segment = measure.firstSegment;
            while (segment) {
                for (var track = 0; track < curScore.ntracks; track++)
                    inspectBarLine(segment.elementAt(track));
                segment = segment.nextInMeasure;
            }

            // MuseScore 3.3+ also exposes measure-related elements here.
            if (measure.elements) {
                for (var elementIndex = 0; elementIndex < measure.elements.length; elementIndex++)
                    inspectBarLine(measure.elements[elementIndex]);
            }

            return flags;
        }

        // Nolasa akordu simbolus tieši no MuseScore Harmony anotācijām.
        function getHarmoniesInMeasure(measure) {
            var harmonies = [];
            var segment = measure.firstSegment;

            while (segment) {
                if (segment.annotations) {
                    var foundAtThisTick = false;

                    for (var i = 0; i < segment.annotations.length; i++) {
                        var annotation = segment.annotations[i];

                        if (annotation &&
                            annotation.type === Element.HARMONY &&
                            !foundAtThisTick) {

                            harmonies.push({
                                tick: segment.tick,
                                text: convertHarmony(annotation.text)
                            });
                            foundAtThisTick = true;
                        }
                    }
                }

                segment = segment.nextInMeasure;
            }

            harmonies.sort(function(a, b) {
                return a.tick - b.tick;
            });

            return harmonies;
        }

        function roundedNumber(value) {
            return Math.round(value * 1000) / 1000;
        }

        // Nosaka mazāko vajadzīgo šūnas soli konkrētajai taktij.
        // Parasti viena šūna ir viens rakstītais sitiens.
        // Ja Harmony atrodas pus-sitienā, lieto astotdaļas šūnas.
        function getGridTicks(harmonies, beatTicks) {
            for (var i = 0; i < harmonies.length; i++) {
                var relativeTick = harmonies[i].tick - currentBarStartTick;
                var fraction = relativeTick / beatTicks;
                if (Math.abs(fraction - Math.round(fraction)) > 0.001)
                    return beatTicks / 2;
            }
            return beatTicks;
        }

        // Veido tieši tik iReal šūnu, cik taktī ir sitienu/izvēlētā režģa vienību.
        // Akorda teksts pats jau aizņem vienu šūnu:
        // 4/4 ar C visu takti => ,C, , ,    (nevis ,C, , , , )
        function buildMeasureTextFromChordDurations(measure, measureNumber) {
            var harmonies = getHarmoniesInMeasure(measure);
            var beatTicks = beatTicksForTimeSignature(currentTimeSig);
            var gridTicks = getGridTicks(harmonies, beatTicks);

            var measureStartTick = currentBarStartTick;
            var measureEndTick;

            // Ņem īsto nākamās takts sākumu, lai garums strādā arī
            // nepilnām/pickup taktīm un pēc taktsmēra maiņas.
            if (measure.nextMeasure && measure.nextMeasure.firstSegment) {
                measureEndTick = measure.nextMeasure.firstSegment.tick;
            } else {
                measureEndTick = measureStartTick + currentBarTicks;
            }

            var measureTicks = measureEndTick - measureStartTick;
            if (!(measureTicks > 0)) {
                measureTicks = currentBarTicks;
                measureEndTick = measureStartTick + measureTicks;
            }

            var cellsInMeasure = Math.round(measureTicks / gridTicks);
            var output = "";
            var activeChord = previousHarmonyText;
            var harmonyIndex = 0;

            // Katra iterācija izvada vienu un tikai vienu takts šūnu.
            for (var cell = 0; cell < cellsInMeasure; cell++) {
                var cellTick = measureStartTick + cell * gridTicks;
                var newChordAtThisCell = false;

                while (harmonyIndex < harmonies.length &&
                       harmonies[harmonyIndex].tick <= cellTick) {
                    activeChord = harmonies[harmonyIndex].text;
                    newChordAtThisCell = true;
                    harmonyIndex++;
                }

                if (activeChord === "") {
                    output += ",n";
                } else if (newChordAtThisCell || cell === 0) {
                    output += "," + activeChord +",";
                } else {
                    output += " ";
                }
            }

            // Debug atskaite: ilgumu rēķina no Harmony tickiem, nevis no teksta.
            var soundingEvents = [];

            if (previousHarmonyText !== "" &&
                (harmonies.length === 0 || harmonies[0].tick > measureStartTick)) {
                soundingEvents.push({
                    tick: measureStartTick,
                    text: previousHarmonyText,
                    continued: true
                });
            }

            for (var h = 0; h < harmonies.length; h++) {
                soundingEvents.push({
                    tick: harmonies[h].tick,
                    text: harmonies[h].text,
                    continued: false
                });
            }

            for (var e = 0; e < soundingEvents.length; e++) {
                var event = soundingEvents[e];
                var nextTick = (e + 1 < soundingEvents.length)
                             ? soundingEvents[e + 1].tick
                             : measureEndTick;

                var startBeat = ((event.tick - measureStartTick) / beatTicks) + 1;
                var durationBeats = (nextTick - event.tick) / beatTicks;
                var continuation = event.continued
                                 ? " [turpinās no iepriekšējās takts]"
                                 : "";

                console.log("Takts " + measureNumber +
                            ": " + event.text +
                            " sākas sitienā " + roundedNumber(startBeat) +
                            ", skan " + roundedNumber(durationBeats) +
                            " sitienus" + continuation);
            }

            console.log("Takts " + measureNumber +
                        ": eksporta šūnas = " + cellsInMeasure +
                        ", takts garums sitienos = " +
                        roundedNumber(measureTicks / beatTicks));

            if (harmonies.length > 0)
                previousHarmonyText = harmonies[harmonies.length - 1].text;

            return output;
        }

        var measure = curScore.firstMeasure;
        var measureNumber = 0;
        var firstMeasure = true;
        var previousBoundaryWasEndStart = false;

        while (measure) {
            measureNumber++;
            var repeats = getMeasureRepeats(measure);
            var timeSignatureToken = getTimeSignatureTokenForMeasure(measure, firstMeasure);
            // Harmony ticki ir segment.tick koordinātēs, tādēļ arī takts
            // sākums jāņem no pirmā segmenta, nevis measure.tick.
            currentBarStartTick = measure.firstSegment
                                ? measure.firstSegment.tick
                                : 0;
            measureText = "";

            // The first token goes before the chart opening barline:
            // T44[C ... rather than [T44C ...
            if (firstMeasure) {
                iReal += timeSignatureToken;
                if (!repeats.start)
                    iReal += "[";
            } else {
                // A changed signature belongs before the already emitted
                // boundary entering this measure: ... C T98|D- ...
                insertBeforePreviousBoundary(timeSignatureToken);
            }

            // A START_REPEAT belongs before this measure and replaces
            // the ordinary incoming "|" boundary.
            if (repeats.start && !previousBoundaryWasEndStart) {
                if (!firstMeasure && iReal.charAt(iReal.length - 1) === "|")
                    iReal = iReal.substr(0, iReal.length - 1);
                iReal += "{";
            }

            var voltaToken = voltaTokensByMeasureTick["" + currentBarStartTick];
            if (voltaToken !== undefined && voltaToken !== null) {
                iReal += voltaToken;
                console.log("Takts " + measureNumber +
                            ": pievienots voltas marķieris " + voltaToken);
            }

            measureText = buildMeasureTextFromChordDurations(measure, measureNumber);

            iReal += measureText;

            // Export MuseScore repeat boundaries in iReal syntax:
            // "|" = ordinary barline, "{" = repeat start, "}" = repeat end.
            if (repeats.endStart) {
                iReal += "}{";
                previousBoundaryWasEndStart = true;
            } else if (repeats.end) {
                iReal += "}";
                previousBoundaryWasEndStart = false;
            } else {
                iReal += "|";
                previousBoundaryWasEndStart = false;
            }

            firstMeasure = false;
            measure = measure.nextMeasure;
        }

        // Final cleanup. A normal trailing barline is replaced by final "Z"
        // below; repeat-ending "}" must be preserved before "Z".
        iReal = iReal.replace(/\|\|+/g, "|")
                     .replace(/,( \( \))+?/g, ",( )");
        if (iReal.charAt(iReal.length - 1) === "|")
            iReal = iReal.substr(0, iReal.length - 1);

        console.log("iReal Pro format with iReal barline markers:");
        console.log(iReal);

        var title = curScore.title || "Untitled";
        var composer = curScore.composer || "Unknown";
        var offset = title.indexOf(" by ");
        if (offset > 0) {
            var tempTitle = title;
            title = tempTitle.substring(0, offset);
            composer = tempTitle.substring(offset + 4);
        }

        var composerParts = composer.split(" ");
        if (composerParts.length === 2)
            composer = composerParts[1] + " " + composerParts[0];

        var signature = curScore.keysig + 7;
        var key = ["Cb", "Gb", "Db", "Ab", "Eb", "Bb", "F", "C", "G", "D", "A", "E", "B", "F#"];
        // The opening "[" is part of iReal now, because the initial
        // time-signature token must be emitted before it: T44[...
        var header = "irealbook://" + title + "=" + composer + "=Medium Swing=" +
                     key[signature] + "=n=";
        var fullOutput = header + iReal + "Z";

        console.log("Full iReal Pro format:");
        console.log(fullOutput);

        var htmlContent = "<!DOCTYPE html>\n" +
            "<html>\n" +
            "<head>\n" +
            "  <meta charset=\"UTF-8\">\n" +
            "  <title>iReal Pro Chart - " + title + "</title>\n" +
            "</head>\n" +
            "<body>\n" +
            "  <h1>" + title + " - " + composer + "</h1>\n" +
            "  <p>\n" +
            "    <a href=\"" + fullOutput + "\">\n" +
            "      Open in iReal Pro\n" +
            "    </a>\n" +
            "  </p>\n" +
            "</body>\n" +
            "</html>";

        var filePath = fileIO.homePath() + "/Desktop/irealpro_chart.html";
        fileIO.source = filePath;
            
        if (fileIO.write(htmlContent)){
            successDialog.visible = true;

        }else{
            errorDialog.visible = true;
           }
        Qt.quit();
    }
}
