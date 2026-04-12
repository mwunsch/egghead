ExUnit.start()

# Start PubSub globally for all web tests.
# ConnCase needs it before starting the endpoint.
{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Egghead.PubSub)
