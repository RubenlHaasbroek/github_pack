# Water-Saving Shower: Selected Software Code Snippets

**Author:** Ruben Haasbroek  
**Student number:** 26865238  
**Project:** Mechanical Project 478  
**Date:** 22 October 2026

This pack presents short extracts from the integrated Raspberry Pi software and the later CNN command recogniser. Ellipses and comments identify omitted implementation detail. The complete source files should be retained separately in the GitHub repository.

## Final hydraulic-control configuration

The final report is the authority for the tested configuration. Conflicting constants in older backup files are not reproduced here.

| Parameter | Final value |
|---|---|
| Wake-word threshold | 0.65 |
| Proportional gain, Kp | 0.15 |
| Integral gain, Ki | 0.015 |
| Time-proportional output period | 6 s |
| Sensor-polling interval | 1 s |
| Control-loop interval | 0.5 s |
| Over-temperature software threshold | 42 °C |
| Missing-reading response | 3 checks (approximately 1.5 s) |

## Final CNN configuration

The values below follow the final report, even where older development scripts contain earlier defaults.

| Parameter | Selected value |
|---|---|
| Model | CNN v2 run 1 |
| Output classes | `go`, `on`, `stop`, `up`, `down`, `_unknown_`, `_noise_` |
| Model input | 1 s of 16 kHz mono audio |
| Feature input | 49 x 40 log-mel spectrogram |
| Command buffer | 4 s |
| Sliding-window hop | 100 ms (1,600 samples) |
| Decision rule | Mean probability over 3 adjacent windows (rule A) |
| Acceptance threshold: `go`, `on`, `stop` | 0.90 |
| Acceptance threshold: `up`, `down` | 0.95 |

## Selected extracts

### 1. System thread structure

**Source:** `main.py`, lines 78–86

Shows how voice, sensing, control, web-interface and scheduling functions were run concurrently on the Raspberry Pi.

```python
threads = [
    threading.Thread(target=voice_thread_loop, args=(gate, stop_event), daemon=True),
    threading.Thread(target=sensor_thread_loop, args=(gate, stop_event, status_ref), daemon=True),
    threading.Thread(target=control_thread_loop, args=(gate, stop_event, controller_ref), daemon=True),
    threading.Thread(target=web_thread_loop, args=(gate, stop_event, controller_ref, status_ref), daemon=True),
    threading.Thread(target=scheduler_thread_loop, args=(gate, stop_event), daemon=True),
]
for t in threads:
    t.start()
```

### 2. Vosk command vocabulary

**Source:** `voice.py`, lines 94–124

The restricted grammar covers warm-up, shower delivery, shutdown and absolute temperature commands. Temperature phrases are generated across the permitted range instead of being written individually.

```python
COMMAND_PHRASES = [
    "start", "start shower", "shower start",
    "shower on", "on shower", "open shower", "shower open",
    "stop", "stop shower", "off", "turn off",
]

for temperature in range(config.MIN_TEMP_C, config.MAX_TEMP_C + 1):
    words = _number_to_words(temperature)
    COMMAND_PHRASES.extend([
        f"set to {words} degrees",
        f"set temperature to {words} degrees",
        f"{words} degrees",
    ])

VOSK_GRAMMAR = json.dumps(COMMAND_PHRASES + ["[unk]"])
```

### 3. openWakeWord activation and Vosk transcription

**Source:** `voice.py`, lines 456–466 and 305–311

openWakeWord compares its prediction with the selected activation threshold. After activation, Vosk transcribes the recorded command using the restricted grammar. The final report identifies 0.65 as the selected wake threshold.

```python
prediction = wake_model.predict(model_audio)
for _, score in prediction.items():
    numeric_score = float(np.asarray(score).squeeze())
    if numeric_score > config.WAKE_WORD_THRESHOLD:
        wake_score_holder["score"] = numeric_score
        wake_detected.set()
        break

recognizer = vosk.KaldiRecognizer(
    vosk_model,
    MODEL_SAMPLE_RATE,
    VOSK_GRAMMAR,
)
```

### 4. Mapping recognised text to control requests

**Source:** `voice.py`, lines 267–300

Recognised phrases are converted into shared request types. Shutdown is checked first, followed by shower delivery, warm-up and a bounded temperature request.

```python
text = text.lower().strip()

if "off" in text or "stop" in text:
    return {"type": "off"}

if ("shower on" in text or "on shower" in text
        or "open shower" in text or "shower open" in text):
    return {"type": "shower_on"}

if "start" in text:
    return {"type": "on"}

# Number extraction omitted here for brevity.
if (temperature is not None
        and config.MIN_TEMP_C <= temperature <= config.MAX_TEMP_C):
    return {"type": "set_temp", "value": temperature}
```

### 5. Feedforward and PI temperature control

**Source:** `pid.py`, lines 4–14 and 30–52

The controller estimates the required hot-water fraction from the inlet temperatures, then adds a bounded PI correction from the mixed-outlet error. Integral accumulation is suspended when the proposed correction saturates.

```python
fraction = (setpoint - cold_temp) / (hot_temp - cold_temp)
feedforward = max(0.0, min(1.0, fraction))

proposed_integral = self._integral + error * dt
output = self.kp * error + self.ki * proposed_integral
if self.output_min <= output <= self.output_max:
    self._integral = proposed_integral
trim = max(self.output_min, min(self.output_max, output))

hot_fraction = max(0.0, min(1.0, feedforward + trim))
```

### 6. Time-proportional inlet-valve selection

**Source:** `pid.py and valve.py`, lines pid.py 55–60; valve.py 23–34

The commanded hot-water fraction is converted into hot- and cold-valve durations within each output period. Only one inlet valve is commanded open at a time.

```python
hot_duration = hot_fraction * period
which = "hot" if elapsed_in_period < hot_duration else "cold"

relay.set_pin(config.V1_HOT_PIN, which == "hot")
relay.set_pin(config.V2_COLD_PIN, which == "cold")
self.v1_open = (which == "hot")
self.v2_open = (which == "cold")
```

### 7. Diversion and shower-outlet interlock

**Source:** `valve.py`, lines 36–44

V3 and V4 receive opposite commands so that the recovery and shower paths are not commanded open together.

```python
def _set_divert_outlet(self, diverting):
    if diverting:
        relay.set_pin(config.V3_DIVERT_PIN, True)
        relay.set_pin(config.V4_OUTLET_PIN, False)
    else:
        relay.set_pin(config.V3_DIVERT_PIN, False)
        relay.set_pin(config.V4_OUTLET_PIN, True)
    self.v3_open = diverting
    self.v4_open = not diverting
```

### 8. Protective response during showering

**Source:** `valve.py`, lines 89–114

An excessive or missing mixed-outlet reading increments the unsafe counter. After the required consecutive checks, the controller returns to HEATING; the final line then commands diversion rather than shower delivery.

```python
if self.state == "showering":
    unsafe_now = (
        mixed_temp is None
        or mixed_temp > config.MAX_SAFE_SHOWER_TEMP_C
    )
    self._unsafe_tick_count = (
        self._unsafe_tick_count + 1 if unsafe_now else 0
    )
    leaving_ready = (
        self._unsafe_tick_count
        >= config.SHOWER_UNSAFE_TICKS_REQUIRED
    )

if self.state in ("ready", "showering") and leaving_ready:
    self.state = "heating"

self._set_divert_outlet(diverting=(self.state != "showering"))
```

### 9. Logged experimental variables

**Source:** `logger.py`, lines 14–19 and 32–48

Each record links the operating state and sensor readings with commanded valve states, controller output, temperature error and flow value.

```python
writer.writerow([
    "timestamp", "event", "state", "shower_on", "setpoint_c",
    "hot_inlet", "cold_inlet", "mixed_outlet",
    "v1_open", "v2_open", "v3_open", "v4_open",
    "hot_fraction", "error_c", "flow_lpm",
])

writer.writerow([
    datetime.now().isoformat(timespec="seconds"),
    event, state, gate_snapshot.get("shower_on"),
    gate_snapshot.get("setpoint_c"),
    sensors.get("hot_inlet"), sensors.get("cold_inlet"),
    sensors.get("mixed_outlet"),
    valves.get("v1_open"), valves.get("v2_open"),
    valves.get("v3_open"), valves.get("v4_open"),
    hot_fraction, error_c, flow_lpm,
])
```

## CNN command-recogniser extracts

### 10. Log-mel feature extraction

**Source:** `voice_kws.py`, lines 35–46 and 64–67

One second of 16 kHz audio is divided into 30 ms frames at a 20 ms step. The saved mel matrix converts each magnitude spectrum to 40 bands, producing the 49 x 40 input described in Section 6.6.

```python
RATE = 16000
FRAME_LEN, FRAME_STEP, FFT_LEN = 480, 320, 512
N_FRAMES = 1 + (RATE - FRAME_LEN) // FRAME_STEP  # 49

HANN = 0.5 - 0.5 * np.cos(
    2 * np.pi * np.arange(FRAME_LEN) / FRAME_LEN
)
IDX = (np.arange(FRAME_LEN)[None, :]
       + FRAME_STEP * np.arange(N_FRAMES)[:, None])

def _features(wav, mel):
    magnitude = np.abs(np.fft.rfft(wav[IDX] * HANN, n=FFT_LEN))
    return np.log(magnitude @ mel + 1e-6).astype(np.float32)
```

### 11. Deployed three-window decision rule

**Source:** `voice_kws_sliding.py`, lines 8–33

The 4 s command buffer produces 31 overlapping one-second windows. Rule A averages each class probability over three adjacent windows and selects the strongest command-class average. The selected thresholds are stated explicitly.

```python
WIN, HOP, K = 16000, 1600, 3
COMMANDS = ("go", "on", "stop", "up", "down")
vk.KWS_THRESHOLD = 0.90
vk.UPDOWN_THRESHOLD = 0.95

for start in range(0, len(wav) - WIN + 1, HOP):
    features = vk._features(wav[start:start + WIN], mel)
    interp.set_tensor(input_index, features[None, ..., None])
    interp.invoke()
    probabilities.append(interp.get_tensor(output_index)[0].copy())

probabilities = np.asarray(probabilities)
smoothed = np.asarray([
    probabilities[i:i + K].mean(axis=0)
    for i in range(len(probabilities) - K + 1)
])
command_indices = [labels.index(word) for word in COMMANDS]
window, command = np.unravel_index(
    np.argmax(smoothed[:, command_indices]),
    smoothed[:, command_indices].shape,
)
label = labels[command_indices[command]]
confidence = float(smoothed[window, command_indices[command]])
```

### 12. Threshold and system-state checks

**Source:** `voice_kws.py`, lines 120–141 and 171–189

Low-confidence outputs create no request. The `on`, `up` and `down` commands also require the shower state to be active. An accepted word is submitted to the software Gate; this line does not operate a relay.

```python
required = UPDOWN_THRESHOLD if label in ("up", "down") else KWS_THRESHOLD
if confidence < required:
    return {"type": "unknown"}

if label == "on" and not _current_setpoint(gate)[1]:
    return {"type": "unknown"}

if label in WORD_COMMANDS:
    return dict(WORD_COMMANDS[label])

if label in ("up", "down"):
    current, shower_on = _current_setpoint(gate)
    if not shower_on:
        return {"type": "unknown"}
    step = 1 if label == "up" else -1
    target = min(max(round(current) + step,
                     config.MIN_TEMP_C), config.MAX_TEMP_C)
    return {"type": "set_temp", "value": target}

# In the voice loop, the accepted request is sent to the Gate.
gate.set_command(command)
```

### 13. Controlled shower-noise preparation

**Source:** `testset_sweep.py`, lines 42–43 and 53–62

Prepared command clips are placed at a random position in a 4 s buffer. Held-out shower noise is scaled from the loudest 0.4 s of the word to produce the requested SNR, matching Equations 6.6 and 6.7.

```python
def speech_rms(clip):
    energy = window_rms(clip, 6400)       # 0.4 s at 16 kHz
    return float(np.sqrt(energy.max() / 6400))

buffer = np.zeros(4 * RATE)
offset = int(rng.uniform(0.1, 1.3) * RATE)
n_samples = min(len(clip), len(buffer) - offset)
buffer[offset:offset + n_samples] = clip[:n_samples]

noise = held_out_shower[start:start + len(buffer)]
noise_rms = np.sqrt(np.mean(noise ** 2))
gain = speech_rms(clip) / (10 ** (snr_db / 20) * noise_rms)
buffer += noise * gain
```

### 14. Correct, missed and wrongly accepted outcomes

**Source:** `decision_rules.py`, lines 33–41

The development comparison applies the same smoothing and class-dependent thresholds to each prepared buffer. A score below threshold is a miss; an accepted label is correct only when it matches the spoken command.

```python
command_classes = [
    i for i, label in enumerate(labels) if label in KWS_ITEMS
]
averages = np.asarray([
    probabilities[w:w + k, command_classes].mean(axis=0)
    for w in range(len(probabilities) - k + 1)
])
window, command = np.unravel_index(np.argmax(averages), averages.shape)
label = labels[command_classes[command]]
confidence = float(averages[window, command])

if confidence < (threshold_ud if label in ("up", "down") else threshold):
    outcome = "missed"
else:
    outcome = "correct" if label == spoken_word else "wrong"
```

### 15. Live-command SNR calculation

**Source:** `live_round_snr.py`, lines 11–24

For the separate live trials, noise is estimated from 0.1 s frames outside the word. Speech power is taken from the loudest 0.4 s after subtracting the estimated noise power. Correctly blocked requests are retained as a separate valid outcome rather than counted in the command-recognition denominator.

```python
frame_rms = np.sqrt(
    (audio[:n * 1600].reshape(n, 1600) ** 2).mean(axis=1)
)
energy = np.concatenate(([0.0], np.cumsum(audio ** 2)))
word_energy = energy[6400:] - energy[:-6400]
word_start = int(np.argmax(word_energy))

frame_start = np.arange(n) * 1600
noise_frames = ((frame_start + 1600 <= word_start - 1600)
                | (frame_start >= word_start + 6400 + 1600))
noise_rms = max(float(np.median(frame_rms[noise_frames])), 1e-6)
speech_power = max(word_energy[word_start] / 6400 - noise_rms ** 2, 1e-12)
snr_db = 10 * np.log10(speech_power / noise_rms ** 2)

VALID_OUTCOMES = ("correct", "blocked (off), correct")
```

The snippets above support the deployed inference and evaluation method without reproducing the full scripts. The model-construction notebook was not among the supplied Python files, so no CNN layer-definition code has been reconstructed. The architecture and training values remain those reported in Section 6.6.

## MATLAB/Simulink verification extracts

### 16. Controller settings and feedforward calculation

**Source:** `pi_controller_skripsie.m`, lines 7–19

The worked MATLAB calculation uses the final proportional gain, integral gain, output period and controller step. The example inlet temperatures below illustrate the feedforward equation; they are not the fixed inlet assumptions used in the separate Simulink figure.

```matlab
Kp = 0.15;      % 1/degC
Ki = 0.015;     % 1/(degC s)
P  = 6;         % time-proportional output period (s)
dt = 0.5;       % controller interval (s)

Tset = 37;
Thot = 45.9;
Tcold = 25.3;
f_ff = (Tset - Tcold)/(Thot - Tcold);
```

### 17. PI correction with conditional integration

**Source:** `pi_controller_skripsie.m`, lines 31–44

The candidate integral is retained only when the unsaturated PI correction lies within its permitted range. The feedforward and correction terms are then combined and limited to a valid hot-water duty fraction.

```matlab
error = Tset - Tmix;
I_candidate = I + error*dt;
u = Kp*error + Ki*I_candidate;

if u >= -1 && u <= 1
    I = I_candidate;
end

trim = min(1, max(-1, u));
hot_fraction = min(1, max(0, f_ff + trim));
```

### 18. Six-second time-proportional switching

**Source:** `pi_controller_skripsie.m`, lines 60–75

The hot valve is selected while the elapsed time within the current output period is less than the requested hot duration. The complementary interval is assigned to the cold valve in the controller model.

```matlab
time_in_period = 0:dt:P-dt;
hot_duration = hot_fraction*P;
hot_valve_open = time_in_period < hot_duration;
cold_valve_open = ~hot_valve_open;

valve_transitions = sum(diff(hot_valve_open) ~= 0);
```

### 19. Unequal inlet-flow sensitivity

**Source:** `pi_controller_skripsie.m`, lines 77–81

This calculation shows why a temperature-only feedforward fraction can retain an offset when the hot and cold paths have different flow rates.

```matlab
Q_hot = 4.557;     % L/min
Q_cold = 5.180;    % L/min

Tmix = (f_ff*Q_hot*Thot + (1-f_ff)*Q_cold*Tcold) ...
     / (f_ff*Q_hot + (1-f_ff)*Q_cold);
```

The complete Simulink block model is retained as `shower_system_control.slx`. Its exported CSV traces and one combined figure are stored with the simulation results so that the report-supporting outputs can be inspected without MATLAB.
