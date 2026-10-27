const API_VERSION = "2022-11-28";

export function repoContext() {
  const repository = process.env.GITHUB_REPOSITORY;
  if (!repository) throw new Error("GITHUB_REPOSITORY is required");

  const [owner, repo] = repository.split("/");
  if (!owner || !repo) throw new Error(`Invalid GITHUB_REPOSITORY: ${repository}`);

  return { owner, repo };
}

export async function githubRequest(method, path, body) {
  const token = process.env.GITHUB_TOKEN;
  if (!token) throw new Error("GITHUB_TOKEN is required");

  const response = await fetch(`https://api.github.com${path}`, {
    method,
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      "X-GitHub-Api-Version": API_VERSION,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });

  if (response.status === 204) return null;

  const text = await response.text();
  const data = text ? JSON.parse(text) : null;

  if (!response.ok) {
    const message = data?.message ?? response.statusText;
    const error = new Error(`${method} ${path} failed: ${message}`);
    error.status = response.status;
    error.data = data;
    throw error;
  }

  return data;
}

export async function ignoreNotFound(promise) {
  try {
    return await promise;
  } catch (error) {
    if (error.status === 404) return null;
    throw error;
  }
}

export async function paginate(path) {
  const results = [];
  let page = 1;

  while (true) {
    const separator = path.includes("?") ? "&" : "?";
    const data = await githubRequest(
      "GET",
      `${path}${separator}per_page=100&page=${page}`,
    );
    results.push(...data);
    if (data.length < 100) break;
    page += 1;
  }

  return results;
}

export async function ensureLabel({ owner, repo }, label) {
  const encoded = encodeURIComponent(label.name);
  const existing = await ignoreNotFound(
    githubRequest("GET", `/repos/${owner}/${repo}/labels/${encoded}`),
  );

  if (existing) return;

  await githubRequest("POST", `/repos/${owner}/${repo}/labels`, label);
}

export async function addLabels({ owner, repo }, issueNumber, labels) {
  if (labels.length === 0) return;
  await githubRequest("POST", `/repos/${owner}/${repo}/issues/${issueNumber}/labels`, {
    labels,
  });
}

export async function removeLabel({ owner, repo }, issueNumber, label) {
  const encoded = encodeURIComponent(label);
  await ignoreNotFound(
    githubRequest("DELETE", `/repos/${owner}/${repo}/issues/${issueNumber}/labels/${encoded}`),
  );
}

export async function upsertIssueComment({ owner, repo }, issueNumber, marker, body) {
  const comments = await paginate(`/repos/${owner}/${repo}/issues/${issueNumber}/comments`);
  const existing = comments.find((comment) => comment.body?.includes(marker));
  const markedBody = `${marker}\n${body}`;

  if (existing) {
    await githubRequest("PATCH", `/repos/${owner}/${repo}/issues/comments/${existing.id}`, {
      body: markedBody,
    });
    return;
  }

  await githubRequest("POST", `/repos/${owner}/${repo}/issues/${issueNumber}/comments`, {
    body: markedBody,
  });
}
