const PLACEHOLDER_PATTERNS = [
  /^brief description of what this pr does(?: and why it is needed)?\.?$/i,
  /^add screenshots or video recording.*$/i,
  /^attach screenshots or a video.*$/i,
  /^closes #?\(issue number.*$/i,
  /^what you expected to happen\.?$/i,
  /^what actually happened\.?$/i,
  /^steps to reproduce:?$/i,
  /^\s*(n\/a|none|todo|tbd|\.\.\.)\s*$/i,
];

const VISUAL_PATH_PATTERNS = [
  /^Sources\/Fluid\/UI\//,
  /^Sources\/Fluid\/Views\//,
  /^Sources\/Fluid\/Theme\//,
  /^Sources\/Fluid\/Assets\.xcassets\//,
  /^\.github\/screenshots\//,
  /(^|\/)([^/]*View|[^/]*Views|Settings|Onboarding|Overlay|MenuBar|Icon|Animation|Animations)[^/]*\.swift$/,
  /\.xcassets\//,
];

const MEDIA_PATTERNS = [
  /!\[[^\]]*]\([^)]+\)/i,
  /<img\b[^>]*>/i,
  /<video\b[^>]*>/i,
  /https:\/\/github\.com\/[^/\s]+\/[^/\s]+\/assets\/[^\s)]+/i,
  /https:\/\/github\.com\/user-attachments\/assets\/[^\s)]+/i,
  /https?:\/\/[^\s)]+\.(png|jpe?g|gif|webp|mov|mp4|webm)(\?[^\s)]*)?/i,
];

const LINK_PATTERNS = [
  /\b(closes|close|closed|fixes|fix|fixed|resolves|resolve|resolved)\s+#\d+\b/i,
  /(^|\s)#\d+\b/,
  /github\.com\/[^/\s]+\/[^/\s]+\/(issues|pull)\/\d+/i,
  /github\.com\/[^/\s]+\/[^/\s]+\/discussions\/\d+/i,
  /\broadmap\b.*https?:\/\//i,
];

export function normalizeText(value = "") {
  return String(value).replace(/\r\n/g, "\n").trim();
}

export function hasNonPlaceholderContent(value = "") {
  const text = normalizeText(value)
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/^[-*]\s*\[[ xX]\]\s*/gm, "")
    .trim();

  if (!text) return false;
  return !PLACEHOLDER_PATTERNS.some((pattern) => pattern.test(text));
}

export function section(body = "", heading) {
  const lines = normalizeText(body).split("\n");
  const normalizedHeading = heading.toLowerCase();
  const start = lines.findIndex((line) => {
    const match = line.match(/^#{2,3}\s*(.*?)\s*$/);
    return match?.[1]?.toLowerCase() === normalizedHeading;
  });

  if (start === -1) return "";

  const end = lines.findIndex(
    (line, index) => index > start && /^#{2,3}\s+\S/.test(line),
  );
  return lines.slice(start + 1, end === -1 ? undefined : end).join("\n").trim();
}

export function hasCheckedCheckbox(value = "") {
  return /^[-*]\s*\[[xX]\]\s+\S+/m.test(value);
}

export function hasRelatedReference(value = "") {
  const text = normalizeText(value);
  return LINK_PATTERNS.some((pattern) => pattern.test(text));
}

export function hasMedia(value = "") {
  const text = normalizeText(value);
  return MEDIA_PATTERNS.some((pattern) => pattern.test(text));
}

export function hasNoVisualChangeAttestation(value = "") {
  return /^[-*]\s*\[[xX]\]\s+No UI\/visual changes; screenshots\/video are not applicable\./im.test(
    value,
  );
}

export function findVisualFiles(files = []) {
  return files.filter((file) => {
    const basename = file.split("/").at(-1) ?? file;
    return (
      VISUAL_PATH_PATTERNS.some((pattern) => pattern.test(file)) ||
      /View|Settings|Onboarding|Overlay|MenuBar|Icon|Animation/i.test(basename)
    );
  });
}

export function hasTestingEvidence(value = "") {
  const text = normalizeText(value);
  const containsCheckbox = /^[-*]\s*\[[ xX]\]\s+\S+/m.test(text);
  return containsCheckbox ? hasCheckedCheckbox(text) : hasNonPlaceholderContent(text);
}

export function validatePullRequest({ body = "", changedFiles = [] } = {}) {
  const description = section(body, "Description");
  const typeOfChange = section(body, "Type of Change");
  const related = section(body, "Related Issue or Discussion");
  const testing = section(body, "Testing");
  const screenshots = section(body, "Screenshots / Video");
  const visualFiles = findVisualFiles(changedFiles);
  const attestsNoVisualChange = hasNoVisualChangeAttestation(screenshots);
  const requiresMedia = visualFiles.length > 0 && !attestsNoVisualChange;

  const checks = [
    ["Description", hasNonPlaceholderContent(description)],
    ["Type of Change", hasCheckedCheckbox(typeOfChange)],
    ["Related Issue or Discussion", hasRelatedReference(related)],
    ["Testing", hasTestingEvidence(testing)],
    [
      "Screenshots / Video",
      attestsNoVisualChange || hasMedia(screenshots),
    ],
  ];

  const missing = checks
    .filter(([, passed]) => !passed)
    .map(([name]) => name);

  return {
    ok: missing.length === 0,
    missing,
    requiresMedia,
    visualFiles,
    attestsNoVisualChange,
  };
}

export function validateIssueFields(body = "", requiredHeadings = []) {
  const missing = requiredHeadings.filter(
    (heading) => !hasNonPlaceholderContent(section(body, heading)),
  );

  return {
    ok: missing.length === 0,
    missing,
  };
}

export function validateBugIssue(body = "") {
  return validateIssueFields(body, [
    "Describe the bug",
    "Reproduction steps",
    "Expected behavior",
    "Actual behavior",
    "App Version",
    "macOS Version",
    "Architecture",
  ]);
}
