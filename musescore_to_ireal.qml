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
    description: "iReal export: no final Z after ending repeat"
    menuPath: "export.ToiRealPro"
    requiresScore: true;
    QProcess {
         id: proc
     }
    // MuseScore 3 BarLineType values from the plugin API.
    property int barlineDouble: 2
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
                if (last === "|" || last === "]" || last === "}" || last === "{") {
                    suffix = last;
                    iReal = iReal.substr(0, iReal.length - 1);
                }
            }

            iReal += "" + suffix + token;
        }

        // Find exported barlines attached to a measure.
        // iReal Pro barline encoding:
        // DOUBLE -> ]
        // START_REPEAT -> {
        // END_REPEAT -> }
        // END_START_REPEAT -> }{
        function getMeasureBarlines(measure) {
            var flags = { doubleBarline: false, start: false, end: false, endStart: false };

            function inspectBarLine(element) {
                if (!element || element.type !== Element.BAR_LINE)
                    return;

                var barType = Number(element.barlineType);
                if (barType === barlineDouble)
                    flags.doubleBarline = true;
                else if (barType === barlineStartRepeat)
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

        // MuseScore rehearsal marki tiek glabāti segment.annotations.
        // iReal Pro sekciju / navigācijas marķieri:
        // A -> *A, B -> *B, C -> *C, D -> *D,
        // V/Verse -> *V, i/Intro -> *i,
        // S/Segno -> S, Q/Coda -> Q, f/Fermata -> f.
        function rehearsalTextToIRealToken(text) {
            var original = (text === undefined || text === null) ? "" : ("" + text);
            var cleaned = original.replace(/^\s+|\s+$/g, "");
            var upper = cleaned.toUpperCase();

            if (upper === "A" || upper === "A SECTION" || upper === "PANTS")
                return "*A";
            if (upper === "B" || upper === "B SECTION" || upper === "PIEDZIEDĀJUMS" || upper === "PIEDZ")
                return "*B";
            if (upper === "C" || upper === "C SECTION")
                return "*C";
            if (upper === "D" || upper === "D SECTION")
                return "*D";
            if (upper === "V" || upper === "VERSE")
                return "*V";
            if (cleaned === "i" || upper === "INTRO" || upper === "IN" || upper === "IEVADS" )
                return "*i";
            // Segno netiek ņemts no Rehearsal Mark teksta.
            // Īstais MuseScore Segno no "Repeats & Jumps" tiek lasīts zemāk
            // kā Marker elements un iReal eksportā kļūst par "S".


            console.log("Rehearsal mark nav iReal kartē: \"" + original + "\"; izlaists.");
            return "";
        }

        function isRehearsalMark(element) {
            if (!element)
                return false;

            return element.type === Element.REHEARSAL_MARK ||
                   element.name === "RehearsalMark" ||
                   element.name === "Rehearsal Mark";
        }

        function getRehearsalTokenForMeasure(measure) {
            var segment = measure.firstSegment;
            var tokens = [];
            var alreadyAdded = {};

            while (segment) {
                if (segment.annotations) {
                    for (var i = 0; i < segment.annotations.length; i++) {
                        var annotation = segment.annotations[i];

                        if (isRehearsalMark(annotation)) {
                            var token = rehearsalTextToIRealToken(annotation.text);
                            if (token !== "" && alreadyAdded[token] !== true) {
                                alreadyAdded[token] = true;
                                tokens.push(token);
                                console.log("Rehearsal mark: \"" + annotation.text +
                                            "\" -> iReal " + token +
                                            ", tick " + segment.tick);
                            }
                        }
                    }
                }
                segment = segment.nextInMeasure;
            }

            return tokens.join("");
        }

        // MuseScore 3 "Repeats & Jumps" elementi:
        // Marker label:
        //   segno -> iReal S     (takts sākumā, pirms akorda)
        //   codab -> iReal Q     (Coda sadaļas sākums, pirms akorda)
        //   coda  -> iReal Q     (To Coda, pēc takts akordiem)
        //   fine  -> iReal <Fine> (pēc takts akordiem)
        // Jump text:
        //   D.C., D.C. al Fine, D.C. al Coda,
        //   D.S., D.S. al Fine, D.S. al Coda -> iReal staff text.
        function normalizedNavigationText(text) {
            if (text === undefined || text === null)
                return "";

            return ("" + text)
                   .replace(/^\s+|\s+$/g, "")
                   .replace(/\s+/g, " ");
        }

        function jumpTextToIRealToken(text) {
            var cleaned = normalizedNavigationText(text);
            var upper = cleaned.toUpperCase();

            if (upper === "D.C." || upper === "D.C")
                return "|<D.C.>";
            if (upper === "D.C. AL FINE" || upper === "D.C AL FINE")
                return "|<D.C. al Fine>";
            if (upper === "D.C. AL CODA" || upper === "D.C AL CODA")
                return "|<D.C. al Coda>";
            if (upper === "D.S." || upper === "D.S")
                return "|<D.S.>";
            if (upper === "D.S. AL FINE" || upper === "D.S AL FINE")
                return "|<D.S. al Fine>";
            if (upper === "D.S. AL CODA" || upper === "D.S AL CODA")
                return "|<D.S. al Coda>";

            return "";
        }

        function isMarkerElement(element) {
            if (!element)
                return false;

            return element.type === Element.MARKER ||
                   element.name === "Marker";
        }

        function isJumpElement(element) {
            if (!element)
                return false;

            return element.type === Element.JUMP ||
                   element.name === "Jump";
        }

        function getRepeatNavigationTokensForMeasure(measure) {
            var result = {
                beforeChord: "",
                beforeBoundary: ""
            };
            var alreadyAdded = {};

            function addUnique(position, token, debugText) {
                if (!token)
                    return;

                var key = position + "|" + token;
                if (alreadyAdded[key] === true)
                    return;

                alreadyAdded[key] = true;
                result[position] += token;
                console.log(debugText + " -> iReal " + token);
            }

            function inspectElement(element) {
                if (!element)
                    return;

                if (isMarkerElement(element)) {
                    var label = (element.label === undefined || element.label === null)
                              ? ""
                              : ("" + element.label).toLowerCase();

                    if (label === "segno") {
                        addUnique("beforeChord", "|S", "Marker Segno (label=segno)");
                    } else if (label === "codab") {
                        // MuseScore Coda galamērķa simbols: takts sākumā.
                        addUnique("beforeChord", "|Q", "Marker Coda (label=codab)");
                    } else if (label === "coda") {
                        // MuseScore To Coda simbols: pie takts beigām.
                        addUnique("beforeBoundary", "|Q", "Marker To Coda (label=coda)");
                    } else if (label === "fine") {
                        addUnique("beforeBoundary", "|<Fine>", "Marker Fine (label=fine)");
                    }
                }

                if (isJumpElement(element)) {
                    var jumpToken = jumpTextToIRealToken(element.text);
                    if (jumpToken !== "") {
                        addUnique("beforeBoundary", jumpToken,
                                  "Jump \"" + normalizedNavigationText(element.text) + "\"");
                    } else {
                        console.log("Jump nav iReal kartē: \"" +
                                    normalizedNavigationText(element.text) + "\"; izlaists.");
                    }
                }
            }

            // Marker un Jump elementi MuseScore 3 parasti pieder takts elementiem.
            if (measure.elements) {
                for (var i = 0; i < measure.elements.length; i++)
                    inspectElement(measure.elements[i]);
            }

            // Rezerves pārbaude, ja konkrētā MuseScore failā elements
            // ir pieejams caur segment.annotations.
            var segment = measure.firstSegment;
            while (segment) {
                if (segment.annotations) {
                    for (var j = 0; j < segment.annotations.length; j++)
                        inspectElement(segment.annotations[j]);
                }
                segment = segment.nextInMeasure;
            }

            return result;
        }

        // Rehearsal markam jāatrodas PIRMS robežas, kas ievada takti:
        // ...C,*B|F... vai pirmās takts sākumā *A[C...
        // Šo izsauc pirms START_REPEAT aizvieto parasto "|" ar "{".
        function insertRehearsalBeforeIncomingBoundary(token) {
            if (!token)
                return;

            if (iReal.length >= 2 && iReal.substr(iReal.length - 2) === "}{") {
                iReal = iReal.substr(0, iReal.length - 2) + token + "}{";
                return;
            }

            if (iReal.length > 0) {
                var last = iReal.charAt(iReal.length - 1);
                if (last === "|" || last === "]" || last === "}" || last === "{") {
                    iReal = iReal.substr(0, iReal.length - 1) + token + last;
                    return;
                }
            }

            iReal += token;
        }

        // Atrod pirmo redzamo galveno TempoText score sākumā.
        // MuseScore TempoText.tempo ir ceturtdaļnotis sekundē, tāpēc BPM = tempo * 60.
        // iReal URL formātā nav atsevišķa BPM lauka; eksportējam to kā paceltu staff text.
        function getFirstMainTempoInfo() {
            var measure = curScore.firstMeasure;

            while (measure) {
                var segment = measure.firstSegment;
                while (segment) {
                    if (segment.annotations) {
                        for (var i = 0; i < segment.annotations.length; i++) {
                            var annotation = segment.annotations[i];

                            if (annotation &&
                                (annotation.type === Element.TEMPO_TEXT ||
                                 annotation.name === "Tempo")) {
                                // Izlaiž slēptus palīgtempo, ja tādi izmantoti playback līknēm.
                                if (annotation.visible === false)
                                    continue;

                                var bpm = Math.round(Number(annotation.tempo) * 60);
                                if (!(bpm > 0))
                                    continue;

                                console.log("Pirmais galvenais temps: " + bpm + " bpm");
                                return {
                                    bpm: bpm,
                                    token: "<*74Tempo: " + bpm + " bpm>"
                                };
                            }
                        }
                    }
                    segment = segment.nextInMeasure;
                }
                measure = measure.nextMeasure;
            }

            console.log("Nav atrasts redzams TempoText; BPM staff-text netiek pievienots.");
            return { bpm: 0, token: "" };
        }

        // Atrod pirmo Harmony un izmanto tā sakni kā iReal tonalitāti.
        // Piem.: C^7 -> C, Bb7 -> Bb, D-7 vai Dm7 -> D-.
        function getKeyFromFirstHarmony() {
            var measure = curScore.firstMeasure;

            while (measure) {
                var harmonies = getHarmoniesInMeasure(measure);
                if (harmonies.length > 0) {
                    var symbol = harmonies[0].text;
                    var match = symbol.match(/^([A-G](?:#|b)?)(-?)/);

                    if (match) {
                        var harmonyKey = match[1] + (match[2] === "-" ? "-" : "");
                        console.log("Tonalitāte no pirmā akorda " + symbol +
                                    ": " + harmonyKey);
                        return harmonyKey;
                    }
                }
                measure = measure.nextMeasure;
            }

            var fallbackSignature = curScore.keysig + 7;
            var fallbackKeys = ["Cb", "Gb", "Db", "Ab", "Eb", "Bb", "F",
                                "C", "G", "D", "A", "E", "B", "F#"];
            var fallback = fallbackKeys[fallbackSignature];
            console.log("Nav Harmony; tonalitāte no key signature: " + fallback);
            return fallback;
        }

        function isFermataElement(element) {
            if (!element)
                return false;

            return element.type === Element.FERMATA ||
                   element.name === "Fermata";
        }

        // Atrod katras fermatas precīzo MuseScore segment.tick, nevis tikai faktu,
        // ka fermata kaut kur šajā taktī eksistē. Tādēļ iReal "f" var ievietot
        // tajā pašā ritmiskajā šūnā, uz kuras fermata ir uzzīmēta.
        function getFermataTicksForMeasure(measure) {
            var result = [];
            var alreadyFound = {};
            var segment = measure.firstSegment;

            function containsFermata(element) {
                if (!element)
                    return false;

                if (isFermataElement(element))
                    return true;

                if (element.elements) {
                    for (var e = 0; e < element.elements.length; e++) {
                        if (isFermataElement(element.elements[e]))
                            return true;
                    }
                }

                if (element.notes) {
                    for (var n = 0; n < element.notes.length; n++) {
                        var note = element.notes[n];
                        if (note && note.elements) {
                            for (var ne = 0; ne < note.elements.length; ne++) {
                                if (isFermataElement(note.elements[ne]))
                                    return true;
                            }
                        }
                    }
                }

                return false;
            }

            function addFermataTick(tick) {
                var numericTick = Number(tick);
                var key = "" + numericTick;

                if (!isNaN(numericTick) && alreadyFound[key] !== true) {
                    alreadyFound[key] = true;
                    result.push(numericTick);
                    console.log("Fermata atrasta MuseScore tick = " + numericTick);
                }
            }

            while (segment) {
                var foundInSegment = false;

                if (segment.annotations) {
                    for (var a = 0; a < segment.annotations.length; a++) {
                        if (containsFermata(segment.annotations[a])) {
                            foundInSegment = true;
                            break;
                        }
                    }
                }

                if (!foundInSegment) {
                    for (var track = 0; track < curScore.ntracks; track++) {
                        if (containsFermata(segment.elementAt(track))) {
                            foundInSegment = true;
                            break;
                        }
                    }
                }

                if (foundInSegment)
                    addFermataTick(segment.tick);

                segment = segment.nextInMeasure;
            }

            result.sort(function(a, b) { return a - b; });
            return result;
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
        function getGridTicks(harmonies, fermataTicks, beatTicks) {
            for (var i = 0; i < harmonies.length; i++) {
                var relativeTick = harmonies[i].tick - currentBarStartTick;
                var fraction = relativeTick / beatTicks;
                if (Math.abs(fraction - Math.round(fraction)) > 0.001)
                    return beatTicks / 2;
            }

            // Ja fermata ir uz astotdaļas pozīcijas, nedrīkst to pārbīdīt uz
            // tuvāko ceturtdaļsitienu. Paplašina takts režģi līdz astotdaļām.
            for (var f = 0; f < fermataTicks.length; f++) {
                var fermataRelativeTick = fermataTicks[f] - currentBarStartTick;
                var fermataFraction = fermataRelativeTick / beatTicks;
                if (Math.abs(fermataFraction - Math.round(fermataFraction)) > 0.001)
                    return beatTicks / 2;
            }

            return beatTicks;
        }

        // Veido tieši tik iReal šūnu, cik taktī ir sitienu/izvēlētā režģa vienību.
        // Akorda teksts pats jau aizņem vienu šūnu:
        // 4/4 ar C visu takti => ,C, , ,    (nevis ,C, , , , )
        function buildMeasureTextFromChordDurations(measure, measureNumber) {
            var harmonies = getHarmoniesInMeasure(measure);
            var fermataTicks = getFermataTicksForMeasure(measure);
            var beatTicks = beatTicksForTimeSignature(currentTimeSig);
            var gridTicks = getGridTicks(harmonies, fermataTicks, beatTicks);

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
            var fermataIndex = 0;

            // Katra iterācija izvada vienu ritmisko šūnu. "f" pats jaunu
            // šūnu neveido, bet tiek pielikts tai šūnai, kuras tick sakrīt
            // ar MuseScore fermatas segment.tick.
            for (var cell = 0; cell < cellsInMeasure; cell++) {
                var cellTick = measureStartTick + cell * gridTicks;
                var newChordAtThisCell = false;

                while (harmonyIndex < harmonies.length &&
                       harmonies[harmonyIndex].tick <= cellTick) {
                    activeChord = harmonies[harmonyIndex].text;
                    newChordAtThisCell = true;
                    harmonyIndex++;
                }

                // iReal simbols "f" attiecas uz PAŠREIZĒJO šūnu tikai tad,
                // ja tas ir ierakstīts PIRMS šīs šūnas akorda/pauzes.
                // Pretējā gadījumā akords jau patērē šūnu un fermata vizuāli
                // nonāk uz nākamā sitiena.
                while (fermataIndex < fermataTicks.length &&
                       fermataTicks[fermataIndex] < cellTick - 0.001) {
                    fermataIndex++;
                }

                if (fermataIndex < fermataTicks.length &&
                    Math.abs(fermataTicks[fermataIndex] - cellTick) < 0.001) {
                    output += "f";
                    console.log("Takts " + measureNumber +
                                ": iReal fermata f PIRMS šūnas " +
                                (cell + 1) + ", tick = " + cellTick);
                    fermataIndex++;
                }

                if (activeChord === "") {
                    output += ",n";
                } else if (newChordAtThisCell || cell === 0) {
                    output += "," + activeChord + ",";
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

        var firstTempoInfo = getFirstMainTempoInfo();
        var exportedKey = getKeyFromFirstHarmony();

        var measure = curScore.firstMeasure;
        var measureNumber = 0;
        var firstMeasure = true;
        var previousBoundaryWasEndStart = false;
        var previousBoundaryWasDouble = false;

        while (measure) {
            measureNumber++;
            var repeats = getMeasureBarlines(measure);
            var rehearsalToken = getRehearsalTokenForMeasure(measure);
            var navigationTokens = getRepeatNavigationTokensForMeasure(measure);
            var timeSignatureToken = getTimeSignatureTokenForMeasure(measure, firstMeasure);
            // Harmony ticki ir segment.tick koordinātēs, tādēļ arī takts
            // sākums jāņem no pirmā segmenta, nevis measure.tick.
            currentBarStartTick = measure.firstSegment
                                ? measure.firstSegment.tick
                                : 0;
            measureText = "";

            // Taktij ir divas neatkarīgas vizuālās malas:
            // iepriekšējā takts jau izvada savu LABO robežu (|, ], }),
            // bet šī takts vajadzības gadījumā izvada savu KREISO robežu ([, {).
            // Tādēļ section/repeat sākumā vairs nedrīkst dzēst iepriekšējās
            // takts noslēguma barline.
            if (firstMeasure) {
                // Sākumā nav iepriekšējās takts labās malas:
                // T44*A[C ... vai T44*A{C ...
                iReal += timeSignatureToken;
                iReal += rehearsalToken;

                if (repeats.start)
                    iReal += "{";
                else
                    iReal += "[";

                // iReal nav BPM metadatu lauka; rādām pirmo score tempu virs pirmās takts.
                iReal += firstTempoInfo.token;
            } else {
                // Taktsmērs joprojām pieder pirms robežas, kura ievada takti.
                insertBeforePreviousBoundary(timeSignatureToken);

                // Rehearsal mark atrodas jaunās sadaļas sākumā, pēc
                // iepriekšējās takts aizvēršanas un pirms kreisās robežas:
                // ...C]*B[F... vai ...C|*B{F...
                if (rehearsalToken !== "")
                    iReal += rehearsalToken;

                if (previousBoundaryWasEndStart) {
                    // Iepriekšējā takts jau noslēgta ar "}", jaunā sākas ar "{":
                    // ...G7}{C...
                    iReal += "{";
                } else if (repeats.start) {
                    // Atvērta repeat robeža šīs takts kreisajā pusē.
                    iReal += "{";
                } else if (previousBoundaryWasDouble || rehearsalToken !== "") {
                    // Closing double iepriekšējai taktij + opening double
                    // jaunajai taktij: ...C]*B[F...
                    iReal += "[";
                }
            }

            var voltaToken = voltaTokensByMeasureTick["" + currentBarStartTick];
            if (voltaToken !== undefined && voltaToken !== null) {
                iReal += voltaToken;
                console.log("Takts " + measureNumber +
                            ": pievienots voltas marķieris " + voltaToken);
            }

            // Segno un Coda sadaļas sākuma simbols atrodas aiz
            // ienākošās taktssvītras, bet pirms šīs takts akorda:
            // ... |SD- ... un ... |QC ...
            if (navigationTokens.beforeChord !== "") {
                iReal += navigationTokens.beforeChord;
                console.log("Takts " + measureNumber +
                            ": sākuma navigācijas marķieris = " +
                            navigationTokens.beforeChord);
            }

            measureText = buildMeasureTextFromChordDurations(measure, measureNumber);

            iReal += measureText;

            // To Coda, Fine un D.C./D.S. Jump pieder pašas takts saturam
            // un atrodas PIRMS šīs takts labās robežas:
            // ...G7Q|, ...C<Fine>Z, ...G7<D.S. al Coda>]
            if (navigationTokens.beforeBoundary !== "") {
                iReal += navigationTokens.beforeBoundary;
                console.log("Takts " + measureNumber +
                            ": pirms robežas navigācijas marķieris = " +
                            navigationTokens.beforeBoundary);
            }

            // iReal labās takts robežas ir alternatīvas, nevis kombinējamas:
            // ordinary -> | ; closing double -> ] ; closing repeat -> } .
            // "]" un "}" jau IR takts noslēdzošās barlines; "|]" un "|}"
            // rada nepareizu zīmējumu iReal lietotnē.
            if (repeats.endStart) {
                iReal += "}";
                previousBoundaryWasEndStart = true;
                previousBoundaryWasDouble = false;
            } else if (repeats.end) {
                iReal += "}";
                previousBoundaryWasEndStart = false;
                previousBoundaryWasDouble = false;
            } else if (repeats.doubleBarline) {
                iReal += "]";
                previousBoundaryWasEndStart = false;
                previousBoundaryWasDouble = true;
                console.log("Takts " + measureNumber +
                            ": closing DOUBLE BARLINE ir ] (bez lieka |)");
            } else {
                iReal += "|";
                previousBoundaryWasEndStart = false;
                previousBoundaryWasDouble = false;
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

        // iReal tonalitātes lauku aizpilda no pirmā Harmony akorda saknes.
        // Ja Harmony nav, getKeyFromFirstHarmony() jau atgrieza key-signature fallback.
        var header = "irealbook://" + title + "=" + composer + "=Medium Swing=" +
                     exportedKey + "=n=";
        // Ja partitūra beidzas ar MuseScore end-repeat zīmi ":|",
        // iReal teksts šajā vietā jau beidzas ar "}".
        // Tad "Z" nepievieno, citādi beigu repeat vizuāli/sintaktiski
        // tiek papildināts ar nevajadzīgu final barline.
        // Visos pārējos gadījumos skaņdarba beigās saglabā "Z".
        var endsWithEndRepeat = iReal.length > 0 &&
                                iReal.charAt(iReal.length - 1) === "}";
        var finalBarlineToken = endsWithEndRepeat ? "" : "Z";
        var fullOutput = header + iReal + finalBarlineToken;

        if (endsWithEndRepeat)
            console.log("Beigu repeat atrasts: iReal gala Z netiek pievienots.");
        else
            console.log("Beigu repeat nav: iReal gala Z tiek pievienots.");

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
