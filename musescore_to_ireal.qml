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
    // Voltu navigācija notiek mazās porcijās, lai gara partitūra neuzkārtu interfeisu.
    property int voltaStepsPerBatch: 10
    property int maxVoltaNavigationSteps: 200000

    property var collectedVoltaTokens: ({})
    property var foundVoltasDuringNavigation: ({})
    property var visitedVoltaNavigationElements: ({})
    property string previousVoltaNavigationKey: ""
    property int unchangedVoltaNavigationCount: 0
    property int voltaNavigationStep: 0
    property int lastNavigatedChordRestTick: -1
    property var voltaNavigationStartElement: null
    property bool voltaSearchRunning: false

    Timer {
        id: voltaNavigationTimer
        interval: 1
        repeat: true
        running: false

        onTriggered: {
            processNextVoltaNavigationBatch();
        }
    }

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

    /*
       Katras palaišanas sākumā atrod pirmo muzikālo notikumu pēc mazākā tick.
       Ja tas ir CHORD, lietotāja sākuma atlase ir tā pirmā NOTE.
       Ja tas ir REST, lietotāja sākuma atlase ir pati pauze.
       Savukārt next-element voltu navigācijai tiek glabāts CHORD/REST objekts,
       jo MuseScore 3 no NOTE ne vienmēr nonāk līdz VoltaSegment.
    */
    function selectFirstNoteOrRestBeforeNavigation() {
        var bestElement = null;
        var bestTick = -1;
        var cursor = curScore.newCursor();

        // Neizmanto iepriekšējās palaišanas atlasi vai saglabāto objektu.
        voltaNavigationStartElement = null;
        cmd("escape");

        for (var staff = 0; staff < curScore.nstaves; staff++) {
            for (var voice = 0; voice < 4; voice++) {
                cursor.staffIdx = staff;
                cursor.voice = voice;
                cursor.rewind(Cursor.SCORE_START);

                while (cursor.segment) {
                    var element = cursor.element;

                    if (isChordOrRest(element)) {
                        var elementTick = selectedMusicalTick(element);

                        if (elementTick >= 0 &&
                            (bestElement === null || elementTick < bestTick)) {
                            bestElement = element;
                            bestTick = elementTick;
                        }

                        // Šajā balsī pirmais Chord/Rest jau ir agrākais.
                        break;
                    }

                    cursor.next();
                }
            }
        }

        if (!bestElement) {
            console.log("Voltu meklēšana: nav atrasta ne nots, ne pauze.");
            return false;
        }

        // Navigācijas sākumpunkts vienmēr ir Chord vai Rest.
        voltaNavigationStartElement = bestElement;

        // Lietotāja prasītā sākuma atlase: pirmā NOTE vai pirmā REST.
        if ((bestElement.type === Element.CHORD || bestElement.name === "Chord") &&
            bestElement.notes && bestElement.notes.length > 0) {
            curScore.selection.select(bestElement.notes[0], false);
            console.log("Voltu meklēšana: automātiski izvēlēta pirmā NOTS, tick = " +
                        valueText(bestTick));
        } else {
            curScore.selection.select(bestElement, false);
            console.log("Voltu meklēšana: automātiski izvēlēta pirmā PAUZE, tick = " +
                        valueText(bestTick));
        }

        return true;
    }

    // Iegūst segmenta tick arī tad, ja pašlaik ir izvēlēta pati NOTE.
    function selectedMusicalTick(element) {
        var current = element;

        for (var level = 0; current && level < 6; level++) {
            if (current.tick !== undefined)
                return Number(current.tick);
            current = current.parent;
        }

        return -1;
    }

    function startVoltaNavigation() {
        collectedVoltaTokens = {};
        foundVoltasDuringNavigation = {};
        visitedVoltaNavigationElements = {};
        previousVoltaNavigationKey = "";
        unchangedVoltaNavigationCount = 0;
        voltaNavigationStep = 0;
        lastNavigatedChordRestTick = -1;

        if (!voltaNavigationStartElement) {
            console.log("Voltu meklēšana: nav Chord/Rest sākuma elementa.");
            exportToIReal(collectedVoltaTokens);
            return;
        }

        // Sākumā jau tika automātiski izvēlēta pirmā NOTE vai REST.
        // Pirms next-element navigācijas CHORD/REST ir vajadzīgs tehniski,
        // lai MuseScore 3 navigācijas ķēde sasniegtu VoltaSegment.
        curScore.selection.select(voltaNavigationStartElement, false);
        console.log("Voltu meklēšana: next-element sākts no pirmā " +
                    valueText(voltaNavigationStartElement.name) + ".");

        voltaSearchRunning = true;
        voltaNavigationTimer.start();
    }

    function finishVoltaNavigation() {
        voltaNavigationTimer.stop();
        voltaSearchRunning = false;

        console.log("Voltu meklēšana pabeigta; sākas iReal eksports.");
        exportToIReal(collectedVoltaTokens);
    }

    /*
       VoltaSegment navigācijas secībā var parādīties tikai pēc visu nošu/akordu
       izstaigāšanas. Tāpēc volta NEVAR tikt piesaistīta pēdējam navigētajam
       akordam. Jāņem pašas voltas spanner sākuma tick.
    */
    function getVoltaStartTick(voltaSegment) {
        if (!voltaSegment)
            return -1;

        if (voltaSegment.spanner) {
            if (voltaSegment.spanner.tick !== undefined) {
                var directSpannerTick = Number(voltaSegment.spanner.tick);
                if (!isNaN(directSpannerTick))
                    return directSpannerTick;
            }

            if (voltaSegment.spanner.startElement) {
                var startElementTick = selectedMusicalTick(voltaSegment.spanner.startElement);
                if (startElementTick >= 0 && !isNaN(startElementTick))
                    return startElementTick;
            }
        }

        if (voltaSegment.tick !== undefined) {
            var segmentTick = Number(voltaSegment.tick);
            if (!isNaN(segmentTick))
                return segmentTick;
        }

        if (voltaSegment.parent && voltaSegment.parent.tick !== undefined) {
            var parentTick = Number(voltaSegment.parent.tick);
            if (!isNaN(parentTick))
                return parentTick;
        }

        // Tikai rezerves variants debugam; īstajā gadījumā jāatrod spanner.tick.
        return lastNavigatedChordRestTick;
    }

    /*
       MuseScore 3 neuzrāda voltas measure.elements vai segment.annotations,
       bet VoltaSegment ir sasniedzams ar cmd("next-element").
       Timer sadala navigāciju porcijās, lai gara partitūra neaizturētu UI.
    */
    function processNextVoltaNavigationBatch() {
        if (!voltaSearchRunning)
            return;

        for (var batchStep = 0; batchStep < voltaStepsPerBatch; batchStep++) {
            if (voltaNavigationStep >= maxVoltaNavigationSteps) {
                console.log("Voltu meklēšana: sasniegts drošības limits " +
                            maxVoltaNavigationSteps + ".");
                finishVoltaNavigation();
                return;
            }

            var selectionElements = curScore.selection.elements;
            if (!selectionElements || selectionElements.length === 0) {
                console.log("Voltu meklēšana: pazuda izvēlētais elements.");
                finishVoltaNavigation();
                return;
            }

            var selected = selectionElements[0];
            var currentKey = selectedElementKey(selected);

            if (currentKey === previousVoltaNavigationKey) {
                unchangedVoltaNavigationCount++;
                if (unchangedVoltaNavigationCount >= 5) {
                    finishVoltaNavigation();
                    return;
                }
            } else {
                unchangedVoltaNavigationCount = 0;
            }
            previousVoltaNavigationKey = currentKey;

            // Atceras pēdējā apmeklētā muzikālā elementa tick rezerves variantam.
            if (isChordOrRest(selected) ||
                selected.type === Element.NOTE ||
                selected.name === "Note") {
                var musicalTick = selectedMusicalTick(selected);
                if (musicalTick >= 0 && !isNaN(musicalTick))
                    lastNavigatedChordRestTick = musicalTick;
            }

            if (isVoltaSegment(selected)) {
                var endingNumber = Number(selected.volta_ending);
                var token = "N" + endingNumber;
                var voltaStartTick = getVoltaStartTick(selected);
                var foundKey = token + "|" + voltaStartTick;

                console.log("VoltaSegment atrasts: ending = " + valueText(endingNumber) +
                            ", spannerTick/sākuma tick = " + valueText(voltaStartTick));

                if (voltaStartTick >= 0 &&
                    !isNaN(endingNumber) &&
                    foundVoltasDuringNavigation[foundKey] !== true) {
                    foundVoltasDuringNavigation[foundKey] = true;
                    collectedVoltaTokens["" + voltaStartTick] = token;

                    console.log("Atrasta volta: " + token +
                                ", piesaistīta SĀKUMA takts tick = " +
                                voltaStartTick);
                }
            }

            // Te apzināti nav visitedElements pārtraukuma. Dažādi MuseScore
            // elementi var dot vienādu atslēgu; tas agrāk apturēja meklēšanu,
            // pirms VoltaSegment bija sasniegts. Galu nosaka tikai 5 reizes
            // nemainīga atlase vai maxVoltaNavigationSteps.
            voltaNavigationStep++;
            cmd("next-element");
        }
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

    function exportToIReal(voltaTokensByMeasureTick) {
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

        // voltaTokensByMeasureTick jau tika savākti ar Timer navigācijas fāzē.
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

    onRun: {
        if (!curScore) {
            Qt.quit();
            return;
        }

        // Katrā palaišanas reizē nomet veco atlasi un automātiski izvēlas
        // pirmo NOTI vai PAUZI partitūras sākumā.
        if (!selectFirstNoteOrRestBeforeNavigation()) {
            Qt.quit();
            return;
        }

        startVoltaNavigation();
    }
}
