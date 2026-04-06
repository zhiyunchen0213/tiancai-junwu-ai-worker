const BASE_URL = process.env.REVIEW_SERVER_URL || 'http://127.0.0.1:13000';
const TOKEN = process.env.DISPATCHER_TOKEN;

/**
 * Call a long video API endpoint.
 * @param {string} method - HTTP method
 * @param {string} path - Path after /api/longvideo (e.g., '/report')
 * @param {object} [body] - JSON body for POST/PATCH/PUT
 * @returns {Promise<object>} Parsed JSON response
 */
export async function apiCall(method, path, body) {
  const url = `${BASE_URL}/api/longvideo${path}`;
  const opts = {
    method,
    headers: {
      'Authorization': `Bearer ${TOKEN}`,
      'Content-Type': 'application/json',
    },
  };
  if (body) opts.body = JSON.stringify(body);

  const maxRetries = 3;
  for (let attempt = 0; attempt < maxRetries; attempt++) {
    try {
      const resp = await fetch(url, opts);
      const data = await resp.json();
      if (!resp.ok) throw new Error(`HTTP ${resp.status}: ${JSON.stringify(data)}`);
      return data;
    } catch (err) {
      if (attempt < maxRetries - 1) {
        const wait = (attempt + 1) * 5;
        console.error(`[API] ${method} ${path} failed (attempt ${attempt + 1}): ${err.message}. Retry in ${wait}s`);
        await new Promise(r => setTimeout(r, wait * 1000));
      } else {
        throw err;
      }
    }
  }
}

/**
 * Report phase completion to the server.
 */
export async function reportPhase(projectId, event, payload = {}) {
  return apiCall('POST', '/report', { project_id: projectId, event, payload });
}

/**
 * Create an asset record on the server.
 */
export async function createAsset(storyId, type, fields = {}) {
  return apiCall('POST', '/assets', { story_id: storyId, type, ...fields });
}

/**
 * Send heartbeat to the server.
 */
export async function sendHeartbeat(workerId, projectId) {
  return apiCall('POST', '/heartbeat', { worker_id: workerId, project_id: projectId });
}
