# M3 — Speaker identity: research and revised direction

Status: **direction changed**. The original M3 (voice profiles / remembered voice identities) is
withdrawn in favour of calendar attendees plus transcript inference. Research date: 2026-08-12.

---

## 1. What the market actually does

Named-speaker attribution in this category is overwhelmingly **not** biometric. It comes from a
participant roster the tool obtains by joining the call.

| Attribution method | Products |
|---|---|
| Roster / attendee names from joining the call as a bot or participant | Fathom, Granola, Sembly (default), Zoom, Google Meet, most of Fireflies |
| Manual labelling only; naming by voice explicitly not offered | **Rev** ("supports speaker diarization but does not support speaker identification"), Descript |
| True persistent voiceprints | Microsoft Teams Voice & Face Enrollment, Sembly Voice ID, Fireflies, Circleback, Read.ai |

Two facts that decide our design:

- **FluidVoice cannot use the common method.** We are a standalone recorder: no bot joins the call,
  so there is no roster and no per-participant audio stream. Only mixed application audio plus the
  local microphone.
- **No major competitor ships on-device-only voice enrollment.** It exists as an SDK (Picovoice
  Eagle) and in indie apps. There is no market-tested consent or UX pattern to copy.

Fallback behaviour for unknown speakers is universal: Teams, Fireflies, Descript and Rev all fall
back to generic "Speaker 1 / Speaker 2" rather than guessing.

## 2. Legal position on voiceprints

- Illinois BIPA expressly lists "voiceprint" as a biometric identifier. It carries a **private
  right of action** with statutory damages ($1,000 negligent / $5,000 intentional) and, since
  *Rosenbach*, requires no actual injury.
- Texas CUBI has no private right of action but is now aggressively enforced by the state AG
  ($1.4B Meta settlement 2024; $1.375B Google 2025).
- GDPR Article 9: a voice embedding used to identify a person is special-category data. The EDPB's
  virtual-voice-assistant guidance says biometric processing should **not** extend to
  non-registered users — which would remove most of the feature's value in the EU.

Active litigation against directly comparable products:

- *Cruz v. Fireflies.AI* (C.D. Ill., filed 2025-12-18; second suit N.D. Ill. 2026-03). Plaintiff had
  no Fireflies account, joined a meeting where the host had enabled it, and a voiceprint of her was
  generated. Claims: no published retention schedule, no written notice, no written release from
  non-account-holders.
- *In re Otter.ai Privacy Litigation* (N.D. Cal.) — same theory, stacked with federal wiretap and
  California all-party-consent claims.
- *Basich v. Microsoft* (W.D. Wash., filed 2026-02-05) — alleges Teams' **default live
  transcription** extracts voiceprint-like vectors without BIPA notice. Not the enrollment feature;
  the ordinary path.

Microsoft geo-blocks its own opt-in Voice & Face Enrollment in Illinois entirely.

**On-device is not a safe harbour.** No court has held that vendor-inaccessible on-device
processing falls outside BIPA. Apple argued exactly that for on-device face grouping in Photos; a
class was certified in June 2026 regardless. On-device is a mitigation, not an exemption.

## 3. Decision

**Do not build voice profiles.** The value is concentrated in naming *other* participants, which is
precisely the litigated pattern, and we would be doing it without the roster that makes it
defensible for everyone else.

## 4. Revised design — calendar attendees plus transcript inference

Names come from the meeting invite and from what people say. Neither is biometric data, so the
BIPA / CUBI / Article 9 analysis does not apply, and no geographic gating or legal gate is required
before shipping.

**Sources of identity, in order of reliability**

1. **Calendar attendees.** Match the session to a calendar event by time overlap (we already record
   `startedAt` / `endedAt` and `capturedApplication`). EventKit gives display names and emails.
   This yields a *closed candidate set*, which is what makes everything below tractable.
2. **1:1 auto-assignment.** Two attendees and two voice clusters, one already identified as the
   local user → the remaining cluster is the invitee. High confidence, covers a large share of real
   meetings.
3. **Transcript inference for 3+ participants**, ranked by reliability:
   - self-introduction ("This is Sarah", "Sarah here") → strong positive
   - direct address ("Thanks, Sarah") → speaker is **not** Sarah; the next speaker probably is
   - third-person mention ("Sarah said earlier") → weak negative on the speaker
   With a closed candidate set this is a small constraint-satisfaction problem; ruling candidates
   out is often enough to force the remaining assignment.
4. **Manual naming** — already shipped in M2 (rename / reassign / merge, with undo).

**Why the closed candidate set matters more than it looks.** Our ASR mangles proper nouns badly
(observed: "did I sign a lucron?", "She Spile Seashore"). Open-vocabulary name spotting would be
hopeless on that output. Fuzzy-matching against a *known* attendee list is robust — "Sara" / "Sera"
/ "Sarah" all resolve when the candidate set is known in advance.

**Consequence for shipped code.** `MeetingSessionSpeaker.diarizationEmbedding` and
`diarizationEmbeddingObservationCount` are currently persisted to `session.json` specifically so
"embedding/cluster provenance survives for M3". Under this design nothing needs them across
sessions. Stop persisting them; that also retires the *Basich*-style exposure on already-shipped
functionality. Within-session clustering still uses embeddings in memory — that is unavoidable and
is what every product in the category does.

## 5. Constraints and failure modes to design against

- Attendee list is **not** a speaker list. People skip meetings, extras join, two people share one
  room. Never assume a bijection.
- Ad-hoc meetings have no invite. Manual naming remains the fallback and must stay first-class.
- Attendees may appear as bare email addresses with no display name.
- Recurring events, optional attendees, and delegated invites all pollute the candidate set.
- A wrong name is worse than "Speaker 2". Nothing may stick without explicit user confirmation —
  this preserves the original M3 exit criterion of conservative candidates with Yes/No confirmation.
- Calendar access is a new permission prompt, on a product that has already spent user patience on
  microphone and screen-recording permissions. It must be optional and requested in context.
- No cross-meeting memory by voice. Each meeting re-derives names from its own invite. This is the
  privacy-preserving property, not a limitation to engineer around.

## 6. Phasing

1. **Shipped (M2)** — manual rename / reassign / merge with undo.
2. **Next** — calendar match plus 1:1 auto-assignment behind a Yes/No confirmation.
3. **After** — conservative inference for 3+ participants; confirmation still required.
4. **Cleanup, independent of the above** — stop persisting diarization embeddings.

## 7. Open questions

- Does the calendar match key on time overlap alone, or also on the meeting URL / captured app?
- What confidence bar must an inferred name clear before it is even *offered* for confirmation?
- Should a confirmed name persist to the calendar contact, so the same person is proposed faster in
  a later meeting with the same invitee? (Contact-linked, not voice-linked — no biometric issue.)
- Do we surface "no invite found" explicitly, or silently fall back to manual naming?
