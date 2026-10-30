# SPDX-License-Identifier: GPL-3.0-or-later
import asyncio
import unittest

from sensor_bridge.locate import CACHE_SECONDS, Found, Locator, addresses

from .fakes import FakeHub, FakeNetwork, T0


class Stub:
    """Just enough of a HubRunner for the locator."""

    def __init__(self, host, learned_id=None, polling=False):
        self.host, self.learned_id, self.polling = host, learned_id, polling


def locator(net: FakeNetwork, runners, networks=("10.0.0.0/24",)) -> Locator:
    async def probe(host):
        return await net.factory(host).identify()

    loc = Locator(networks, probe, net.tcp)
    loc.runners = runners
    return loc


def find(loc, runner, at=0.0):
    return asyncio.run(loc.find(runner, T0 + at))


class AddressesTest(unittest.TestCase):
    def test_hosts_only_deduplicated_in_order(self):
        got = addresses(["10.0.1.0/30", "10.0.0.0/30", "10.0.1.0/30"])
        self.assertEqual(got, ["10.0.0.1", "10.0.0.2", "10.0.1.1", "10.0.1.2"])


class SweepTest(unittest.TestCase):
    def test_finds_the_hub_by_id_and_ignores_routers_and_other_logins(self):
        a, b = FakeHub(hub_id="A"), FakeHub(hub_id="B")
        net = FakeNetwork(**{"10_0_0_34": a, "10_0_0_56": b})
        net.extra_open.add("10.0.0.1")
        runner = Stub("10.0.0.74", "A")
        loc = locator(net, [runner])
        self.assertEqual(find(loc, runner), Found("10.0.0.34", "A"))
        self.assertEqual(len(net.tcp_calls), 254)
        self.assertEqual(loc.found, {"10.0.0.34": "A", "10.0.0.56": "B"})

    def test_not_found_when_the_hub_is_off(self):
        net = FakeNetwork(**{"10_0_0_34": FakeHub(hub_id="B")})
        runner = Stub("10.0.0.74", "A")
        self.assertIsNone(find(locator(net, [runner]), runner))

    def test_addresses_of_polling_runners_are_not_probed_or_offered(self):
        net = FakeNetwork(**{"10_0_0_34": FakeHub(hub_id="A")})
        ok, lost = Stub("10.0.0.34", "A", polling=True), Stub("10.0.0.74", "B")
        loc = locator(net, [ok, lost])
        self.assertIsNone(find(loc, lost))
        self.assertNotIn("10.0.0.34", net.tcp_calls)

    def test_one_sweep_serves_every_runner_for_a_minute(self):
        net = FakeNetwork(**{"10_0_0_34": FakeHub(hub_id="A"), "10_0_0_56": FakeHub(hub_id="B")})
        ra, rb = Stub("10.0.0.74", "A"), Stub("10.0.0.79", "B")
        loc = locator(net, [ra, rb])
        self.assertEqual(find(loc, ra).host, "10.0.0.34")
        calls = len(net.tcp_calls)
        self.assertEqual(find(loc, rb, 5).host, "10.0.0.56")
        self.assertEqual(len(net.tcp_calls), calls, "cached result, no second sweep")
        find(loc, rb, CACHE_SECONDS + 1)
        self.assertEqual(len(net.tcp_calls), 2 * calls)

    def test_a_second_request_during_a_sweep_gets_nothing_and_starts_no_sweep(self):
        net = FakeNetwork(**{"10_0_0_34": FakeHub(hub_id="A")})
        ra, rb = Stub("10.0.0.74", "A"), Stub("10.0.0.79", "B")
        loc = locator(net, [ra, rb])

        async def both():
            first = asyncio.ensure_future(loc.find(ra, T0))
            await asyncio.sleep(0)
            return loc.busy, await loc.find(rb, T0), await first

        busy, second, first = asyncio.run(both())
        self.assertTrue(busy)
        self.assertIsNone(second)
        self.assertEqual(first.host, "10.0.0.34")
        self.assertEqual(len(net.tcp_calls), 254)

    def test_disabled_without_networks(self):
        net = FakeNetwork(**{"10_0_0_34": FakeHub(hub_id="A")})
        runner = Stub("10.0.0.74", "A")
        loc = locator(net, [runner], networks=())
        self.assertFalse(loc.enabled)
        self.assertIsNone(find(loc, runner))
        self.assertEqual(net.tcp_calls, [])


class ClaimTest(unittest.TestCase):
    def test_a_never_reached_runner_claims_a_hub_no_one_follows(self):
        net = FakeNetwork(**{"10_0_0_34": FakeHub(hub_id="A"), "10_0_0_58": FakeHub(hub_id="C")})
        followed, fresh = Stub("10.0.0.34", "A"), Stub("10.0.0.99")
        self.assertEqual(find(locator(net, [followed, fresh]), fresh), Found("10.0.0.58", "C"))

    def test_it_does_not_take_a_hub_sitting_at_another_runners_address(self):
        net = FakeNetwork(**{"10_0_0_58": FakeHub(hub_id="C")})
        other, fresh = Stub("10.0.0.58"), Stub("10.0.0.99")  # `other` has not connected yet
        self.assertIsNone(find(locator(net, [other, fresh]), fresh))

    def test_two_claimants_never_get_the_same_hub(self):
        net = FakeNetwork(**{"10_0_0_58": FakeHub(hub_id="C")})
        r1, r2 = Stub("10.0.0.97"), Stub("10.0.0.98")
        loc = locator(net, [r1, r2])
        got = find(loc, r1)
        r1.learned_id, r1.host = got.hub_id, got.host  # what the runner does with it
        self.assertIsNone(find(loc, r2, 1))
