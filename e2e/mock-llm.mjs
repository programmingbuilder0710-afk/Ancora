import http from 'node:http';
import { pathToFileURL } from 'node:url';
const date = (today, offset) => {
  const d = new Date(today + 'T12:00:00'); d.setDate(d.getDate() + offset);
  return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
};
export async function startMock() {
  const requests = [];
  const server = http.createServer(async (req, res) => {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Headers', '*');
    res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
    if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }
    try {
      let raw = ''; for await (const chunk of req) raw += chunk;
      const body = JSON.parse(raw);
      requests.push(body);
      const context = JSON.parse(body.messages.find(m => m.role === 'user').content);
      const tasks = context.unfinished_tasks
        ? context.unfinished_tasks.map((t, i) => ({ ...t, recommended_day: date(context.today, Math.min(5, Math.floor(i / 3))), prerequisite_ids: t.prerequisite_ids ?? [] }))
        : context.goals.flatMap((goal, g) => {
          const titles = goal.title.includes('Spanish')
            ? ['Learn everyday greetings', 'Practice a short conversation', 'Build a vocabulary list', 'Listen to a beginner podcast', 'Review useful phrases', 'Try a five-minute conversation']
            : ['Set your training baseline', 'Easy run + mobility', 'Build a weekly training routine', 'Practice a comfortable pace', 'Strength and recovery', 'Complete your first long run'];
          return titles.map((title, i) => ({ task_id: `g${g}-task${i}`, goal_id: goal.goal_id, title,
            duration_minutes: [30,45,45,30,45,60][i], recommended_day: date(context.today, [0,0,1,2,3,4][i]),
            prerequisite_ids: i === 5 ? [`g${g}-task0`] : [] }));
        });
      const result = { tasks, ...(context.unfinished_tasks ? { tips: ['Keep easy runs easy so you have energy for the long run.', 'Practice greetings aloud for five minutes between sessions.'] } : {}) };
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify({ choices: [{ message: { content: JSON.stringify(result) } }] }));
    } catch { res.writeHead(400); res.end('{}'); }
  });
  await new Promise(resolve => server.listen(9999, '127.0.0.1', resolve));
  return { requests, close: () => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }) };
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await startMock(); console.log('Mock listening on :9999');
}
