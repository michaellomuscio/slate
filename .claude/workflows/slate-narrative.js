export const meta = {
  name: 'slate-narrative',
  description: 'Choose which parts of a Slate take to keep — a panel of social-media, storytelling, and marketing experts analyze the transcript for a viewer who does NOT already know what is coming, then a showrunner synthesizes one coherent, engaging narrative cut.',
  phases: [
    { title: 'Lenses', detail: 'social / story / marketing experts each propose a cut' },
    { title: 'Showrunner', detail: 'synthesize one coherent narrative timeline' },
  ],
}

// args: { bundlePath, format: "social"|"course", targetSeconds: number }
const bundle = (args && args.bundlePath) || ''
const format = (args && args.format) || 'social'
const target = (args && args.targetSeconds) || (format === 'social' ? 50 : 240)
if (!bundle) throw new Error('slate-narrative: args.bundlePath is required')

const CONTEXT = `
You are editing a screen-recording ("take") for ${format === 'social' ? 'a vertical SOCIAL clip (TikTok/Reels/Shorts)' : 'an online-COURSE module'}.
Target length: about ${target} seconds${format === 'social' ? ' (tight — 30-60s)' : ''}.

READ THESE FILES in the bundle first (they are the ground truth):
  ${bundle}/take.md            — digest: audio health, app/chapter timeline, clicks, transcript, edit candidates
  ${bundle}/transcript.json    — word + segment level transcript on the GLOBAL timeline (seconds). Fields: segments[].{text,start,end}, words[], silences[], duration. "duration" is the editable end of the take.
You MAY open a few ${bundle}/frames/*.jpg to SEE what is on screen at a given time.

CRITICAL EDITING PRINCIPLES (the user taught these):
1. A long SILENCE in the middle is usually the AI working — it is NOT the end. CUT the silence, but KEEP the good content that comes AFTER it (the payoff often lives there). Never assume "everything after the big gap is junk."
2. Judge from the perspective of a viewer who does NOT already know what the creator is about to do or show. The clip must make sense on its own as a NARRATIVE — a stranger scrolling should understand what this is, get hooked, and feel a payoff. Disconnected facts are not a story.
3. Keep it engaging and TIGHT. Cut boring/rambling/repeated/over-explained parts and false starts. But keep the connective tissue that makes the story cohere — don't cut so aggressively that it stops making sense.
4. Some segments may have NO screen (screen track ended) but DO have the creator's narration + camera — those can still be the payoff. Keeping them is fine; the renderer freezes the last screen frame.

A "keep window" is a [start, end] span in GLOBAL seconds (use segment boundaries from transcript.json). Times must lie within [0, duration].
`

const LENS_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    throughline: { type: 'string', description: 'the one-sentence story this take should tell, from your lens' },
    keepWindows: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        properties: {
          start: { type: 'number' }, end: { type: 'number' },
          role: { type: 'string', description: 'hook | context | demo | payoff | CTA | transition' },
          why: { type: 'string', description: 'why this earns its place for a stranger' },
        },
        required: ['start', 'end', 'role', 'why'],
      },
    },
    cutBoldly: { type: 'array', items: { type: 'string' }, description: 'spans/things to definitely cut + why (rambles, repeats, over-explanation, dead air)' },
    estSeconds: { type: 'number' },
  },
  required: ['throughline', 'keepWindows', 'cutBoldly', 'estSeconds'],
}

const LENSES = [
  { key: 'social', title: 'Social-media expert',
    brief: `You optimize for the SCROLL. First 2-3 seconds must hook or they swipe away. Lead with the boldest claim/result, not throat-clearing. Ruthless on anything slow. You care about retention curve, pattern interrupts, and a clear "why should I care." Pick the single strongest spine and the moments that make someone stop scrolling.` },
  { key: 'story', title: 'Storytelling / narrative expert',
    brief: `You care about ARC: setup → tension → resolution. A stranger must understand WHAT is happening and feel a beginning, middle, and a satisfying payoff. You protect the connective tissue that makes it cohere and you make sure the PAYOFF is present and lands (e.g. the finished result is actually shown/described). You'd rather keep one extra line that makes it make sense than leave a confusing jump cut.` },
  { key: 'marketing', title: 'Marketing / audience-growth expert',
    brief: `You optimize for VALUE and shareability. What is the concrete takeaway the viewer can repeat or use? You frame the problem→solution clearly ("stop paying for X, do this instead"), make the benefit obvious, and ensure there's a reason to follow for more. You cut anything that doesn't build the value proposition or the payoff.` },
]

phase('Lenses')
const analyses = await parallel(LENSES.map((l) => () =>
  agent(
    `${CONTEXT}\n\nYOUR LENS: ${l.title}.\n${l.brief}\n\nProduce your ideal cut: the keepWindows (in global seconds, on segment boundaries) that tell ONE coherent story for a stranger in ~${target}s, plus what to cut boldly. Return the structured object.`,
    { label: `lens:${l.key}`, phase: 'Lenses', schema: LENS_SCHEMA, agentType: 'general-purpose' }
  ).then((r) => ({ lens: l.key, title: l.title, ...r }))
))

const valid = analyses.filter(Boolean)
log(`Collected ${valid.length} expert cuts. Synthesizing the narrative…`)

const TIMELINE_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    title: { type: 'string', description: 'a punchy working title for the clip' },
    throughline: { type: 'string', description: 'the single narrative this cut tells' },
    keepWindows: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        properties: {
          start: { type: 'number' }, end: { type: 'number' },
          role: { type: 'string' },
          why: { type: 'string' },
        },
        required: ['start', 'end', 'role', 'why'],
      },
    },
    narrativeArc: { type: 'array', items: { type: 'string' }, description: 'the clip beat-by-beat, 3-6 bullets' },
    estSeconds: { type: 'number' },
    notes: { type: 'string', description: 'anything the human editor should know (e.g. payoff has no screen → frozen frame; risky cut)' },
  },
  required: ['title', 'throughline', 'keepWindows', 'narrativeArc', 'estSeconds'],
}

phase('Showrunner')
const synthesis = await agent(
  `${CONTEXT}\n\nYou are the SHOWRUNNER. Three experts each proposed a cut. Reconcile them into ONE final cut that a stranger will watch start-to-finish and think "that's cool."\n\n` +
  `Rules for your decision:\n` +
  `- Open on the strongest HOOK (social expert's instinct), ensure a clear ARC (story expert), and land a concrete PAYOFF/takeaway (marketing + story).\n` +
  `- The payoff MUST be present if it exists in the take — re-read transcript.json near the END of the take (after any long silence) to find where the creator shows/describes the result, and KEEP it. Do not end on the setup/tease if a real payoff was recorded.\n` +
  `- Order keepWindows in TIME order (they will be concatenated). They must be non-overlapping, on segment boundaries, within [0, duration], and total roughly ${target}s.\n` +
  `- Cut dead air, the AI-thinking silence, rambles, repeats, over-explanation, and false starts.\n\n` +
  `THE THREE EXPERT CUTS:\n${JSON.stringify(valid, null, 2)}\n\n` +
  `Return the final structured timeline.`,
  { label: 'showrunner', phase: 'Showrunner', schema: TIMELINE_SCHEMA, agentType: 'general-purpose' }
)

return { format, target, lenses: valid, final: synthesis }
