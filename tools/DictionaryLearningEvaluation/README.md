# Original-audio learning evaluation

Offline diagnostics for the production FluidAudio encoder/search APIs. These tools never open a microphone, write the user's dictionary, or download a model. Supply real recordings and an already installed Parakeet v3 model directory. Outputs include transcribed text and acoustic vectors; store them locally.

## Run

Check `xcode-select -p`; use a full Xcode developer directory for Swift commands. From the FluidVoice root:

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta6.app/Contents/Developer
export FLUIDAUDIO_SOURCE=/absolute/path/to/FluidAudio_pronunciation_streaming
swift run -c release --package-path tools/DictionaryLearningEvaluation PersonalProof /absolute/path/to/jensen-120s.wav /absolute/path/to/parakeet-tdt-0.6b-v3-coreml /tmp/personal-trials.json
swift run -c release --package-path tools/DictionaryLearningEvaluation Evaluate /absolute/path/to/fleurs /absolute/path/to/parakeet-tdt-0.6b-v3-coreml /tmp/word-vectors.json
python3 tools/DictionaryLearningEvaluation/analyze_search.py /tmp/word-vectors.json.trials.json /tmp/search-comparison.json
```

Baseline matcher revision: 9725fb6; local-only loader requires companion revision 932842b or later. Default sibling checkout is FluidAudio_pronunciation_streaming; FLUIDAUDIO_SOURCE allows another checkout for comparison. No model or audio is committed here.

Evaluate expects de_de, fr_fr, pl_pl, da_dk, el_gr, ru_ru, es_419 and en_us directories, each with WAV files and a matching LANGUAGE.trans.txt. Each reference line begins with the WAV stem, followed by its reference transcript. It excludes recordings longer than 14.88 seconds. Enrollment is from one clip; all evaluation clips differ from enrollment. Edit-distance reference alignment is approximate and must be inspected before interpreting individual errors.

PersonalProof uses the first occurrence of NVIDIA, Jensen, Huang, design and AI in supplied interview speech. It excludes the entire enrollment window from subsequent search, preserves raw scores and reports release search timings. It ignores a final tail shorter than one second. Its positive counts use ASR text, not independent reference labels: “Hong Kong” will not be counted as a Huang occurrence. Do not use those counts as recall or WER. The 120-second source includes a speaker transition and is not a same-speaker-only benchmark.

## Interpretation and limitations

The analyzer compares known-text matches, acoustic hits at the library's 0.70 search threshold, and combined fallback with 0.85 required for unknown variants. It evaluates one intended label at a time; it does not simulate production competition between dictionary entries or every text-formatting rule. Tests in DictationE2ETests cover those composition behaviors. These thresholds must stay in sync with DictionaryPronunciationDecision; they are not probabilities.

The current FLEURS subset produced text 19 true/2 false substitutions, acoustic 3 true/1 false, combined 19 true/2 false across 21 target and 547 non-target opportunities. This shows preserved text recall, not superiority. The independent later Huang/Hong Kong diagnostic produced no acoustic hit above 0.70. Do not lower thresholds to fit this single miss.

Release search of one profile across a 14.88-second window: 28 calls, median 0.517 ms, range 0.494–0.669 ms on M5 Max. This excludes audio encoding, text reconciliation and Stop scheduling. See docs/design/original-audio-learning-implementation.md for full pipeline validation and resource bounds.
