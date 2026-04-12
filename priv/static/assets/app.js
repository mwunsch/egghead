import { Socket } from "https://cdn.jsdelivr.net/npm/phoenix@1.8.5/priv/static/phoenix.mjs/+esm";
import { LiveSocket } from "https://cdn.jsdelivr.net/npm/phoenix_live_view@1.1.28/priv/static/phoenix_live_view.esm.js/+esm";

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();

window.liveSocket = liveSocket;
