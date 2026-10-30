# SPDX-License-Identifier: GPL-3.0-or-later
import asyncio
import unittest

from sensor_bridge.locate import CACHE_SECONDS, Found, Locator, addresses

from .fakes import FakeHub, FakeNetwork, T0, child


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
    """Ask for a sweep at `at` seconds, let it finish, and pick for the runner."""
    async def go():
        loc.request(T0 + at)
        await loc.wait()
        found = loc.result(T0 + at)
        return None if found is None else loc.pick(runner, found)

    return asyncio.run(go())


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
        self.assertEqual({h: i.hub_id for h, i in loc.found.items()}, {"10.0.0.34": "A", "10.0.0.56": "B"})

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

    def test_a_request_during_a_sweep_starts_no_second_sweep_and_has_no_result_yet(self):
        net = FakeNetwork(**{"10_0_0_34": FakeHub(hub_id="A")})
        ra, rb = Stub("10.0.0.74", "A"), Stub("10.0.0.79", "B")
        loc = locator(net, [ra, rb])

        async def both():
            loc.request(T0)
            first_task = loc.task
            loc.request(T0 + 1)
            return loc.busy, loc.result(T0), loc.task is first_task, await loc.wait()

        busy, early, same, _ = asyncio.run(both())
        self.assertTrue(busy)
        self.assertIsNone(early)
        self.assertTrue(same)
        self.assertEqual(len(net.tcp_calls), 254)
        self.assertEqual(loc.pick(ra, loc.result(T0)).host, "10.0.0.34")

    def test_a_failed_sweep_gives_no_result(self):
        net = FakeNetwork(**{"10_0_0_34": FakeHub(hub_id="A")})
        runner = Stub("10.0.0.74", "A")

        loc = locator(net, [runner], networks=("not-a-network",))  # the sweep itself raises
        with self.assertLogs("sensor_bridge", "ERROR"):
            self.assertIsNone(find(loc, runner))
        self.assertFalse(loc.busy)

    def test_disabled_without_networks(self):
        net = FakeNetwork(**{"10_0_0_34": FakeHub(hub_id="A")})
        runner = Stub("10.0.0.74", "A")
        loc = locator(net, [runner], networks=())
        self.assertFalse(loc.enabled)
        self.assertIsNone(find(loc, runner))
        self.assertEqual(net.tcp_calls, [])


class SafetyTest(unittest.TestCase):
    def test_a_camera_or_other_device_is_never_a_hub_to_follow_or_claim(self):
        net = FakeNetwork(**{"10_0_0_20": FakeHub(hub_id="CAM", children=[child(1)], model="C200"),
                             "10_0_0_21": FakeHub(hub_id="A", children=[child(2)])})
        fresh = Stub("10.0.0.99")
        loc = locator(net, [fresh])
        self.assertEqual(find(loc, fresh), Found("10.0.0.21", "A"))
        self.assertEqual(list(loc.found), ["10.0.0.21"])
        learned = Stub("10.0.0.98", "CAM")
        self.assertIsNone(find(locator(net, [learned]), learned, 100))

    def test_a_hub_without_sensors_is_not_claimed_but_is_followed_by_id(self):
        net = FakeNetwork(**{"10_0_0_20": FakeHub(hub_id="EMPTY")})
        fresh, known = Stub("10.0.0.99"), Stub("10.0.0.98", "EMPTY")
        self.assertIsNone(find(locator(net, [fresh]), fresh))
        self.assertEqual(find(locator(net, [known]), known), Found("10.0.0.20", "EMPTY"))

    def test_an_address_whose_login_was_refused_is_skipped_for_six_sweeps(self):
        net = FakeNetwork(**{"10_0_0_20": FakeHub(hub_id="A", children=[child(1)])})
        net.refuse_login.add("10.0.0.30")
        runner = Stub("10.0.0.74", "A")
        loc = locator(net, [runner])
        seen = []
        for n in range(8):
            before = net.tcp_calls.count("10.0.0.30")
            find(loc, runner, n * 100)
            seen.append(net.tcp_calls.count("10.0.0.30") - before)
        self.assertEqual(seen, [1, 0, 0, 0, 0, 0, 0, 1])

    def test_a_non_polling_runners_address_is_offered_only_when_its_hub_is_that_hub(self):
        net = FakeNetwork(**{"10_0_0_11": FakeHub(hub_id="A", children=[child(1)])})
        a, b = Stub("10.0.0.10", "A"), Stub("10.0.0.11", "B")
        self.assertEqual(find(locator(net, [a, b]), a), Found("10.0.0.11", "A"))
        b.polling = True
        self.assertIsNone(find(locator(net, [a, b]), a, 100))


class ClaimTest(unittest.TestCase):
    def test_a_never_reached_runner_claims_a_hub_no_one_follows(self):
        net = FakeNetwork(**{"10_0_0_34": FakeHub(hub_id="A", children=[child(1)]), "10_0_0_58": FakeHub(hub_id="C", children=[child(3)])})
        followed, fresh = Stub("10.0.0.34", "A"), Stub("10.0.0.99")
        self.assertEqual(find(locator(net, [followed, fresh]), fresh), Found("10.0.0.58", "C"))

    def test_it_does_not_take_a_hub_sitting_at_another_runners_address(self):
        net = FakeNetwork(**{"10_0_0_58": FakeHub(hub_id="C", children=[child(3)])})
        other, fresh = Stub("10.0.0.58"), Stub("10.0.0.99")  # `other` has not connected yet
        self.assertIsNone(find(locator(net, [other, fresh]), fresh))

    def test_two_claimants_never_get_the_same_hub(self):
        net = FakeNetwork(**{"10_0_0_58": FakeHub(hub_id="C", children=[child(3)])})
        r1, r2 = Stub("10.0.0.97"), Stub("10.0.0.98")
        loc = locator(net, [r1, r2])
        got = find(loc, r1)
        r1.learned_id, r1.host = got.hub_id, got.host  # what the runner does with it
        self.assertIsNone(find(loc, r2, 1))
