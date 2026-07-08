// SquatchMail dashboard client bundle.
//
// Host apps that mount `squatch_mail_dashboard` do not need to expose their
// own Phoenix/LiveView JS to our pages — this bundle embeds its own copies of
// `phoenix` and `phoenix_live_view` (the same approach Phoenix LiveDashboard
// and Oban Web use) so the dashboard's LiveViews connect over their own
// socket regardless of what JS the host ships on the rest of the site.
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"

const csrfToken = document
  .querySelector("meta[name='squatch-mail-csrf-token']")
  ?.getAttribute("content")

const socketPath = document
  .querySelector("meta[name='squatch-mail-socket-path']")
  ?.getAttribute("content") || "/live"

const liveSocket = new LiveSocket(socketPath, Socket, {
  params: { _csrf_token: csrfToken },
  hooks: {}
})

liveSocket.connect()

window.squatchMailLiveSocket = liveSocket
