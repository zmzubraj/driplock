package driplock

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

const day = int64(86400)

func TestBackupTakesOverAfterInactivity(cur realm, t *testing.T) {
	reset()
	id := newCoinStream(cur, 1000, 0, 100*day, false)

	testing.SetRealm(testing.NewUserRealm(bob))
	SetBackup(cross(cur), id, dave, 30*day)
	uassert.True(t, strings.Contains(Render("1"), "can take over after"))

	// Too early: the backup must wait the full window.
	sec(29 * day)
	testing.SetRealm(testing.NewUserRealm(dave))
	uassert.AbortsWithMessage(t, cur, "driplock: the recipient is not inactive long enough yet",
		func() { ClaimAsBackup(cross(cur), id) })

	sec(1 * day)
	uassert.True(t, strings.Contains(Render("1"), "can take over now"))
	ClaimAsBackup(cross(cur), id)
	info, _ := GetStream(id)
	uassert.Equal(t, dave, info.Recipient)
	uassert.Equal(t, address(""), info.Backup) // the new owner picks their own

	// The old key is now powerless, and the backup collects what is owed.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "driplock: only the recipient can withdraw", func() { Withdraw(cross(cur), id) })
	testing.SetRealm(testing.NewUserRealm(dave))
	uassert.Equal(t, int64(300), Withdraw(cross(cur), id))
}

func TestRecipientActivityResetsTheTimer(cur realm, t *testing.T) {
	reset()
	id := newCoinStream(cur, 1000, 0, 100*day, false)
	testing.SetRealm(testing.NewUserRealm(bob))
	SetBackup(cross(cur), id, dave, 30*day)

	sec(20 * day)
	Ping(cross(cur), id)
	sec(20 * day)
	Withdraw(cross(cur), id) // own withdraw is activity too
	sec(20 * day)

	testing.SetRealm(testing.NewUserRealm(dave))
	uassert.AbortsWithMessage(t, cur, "driplock: the recipient is not inactive long enough yet",
		func() { ClaimAsBackup(cross(cur), id) })
}

// A relayer must not be able to keep a lost-key stream "alive" and block recovery.
func TestRelayedWithdrawDoesNotResetTheTimer(cur realm, t *testing.T) {
	reset()
	id := newCoinStream(cur, 1000, 0, 100*day, false)
	testing.SetRealm(testing.NewUserRealm(bob))
	SetBackup(cross(cur), id, dave, 30*day)

	sec(25 * day)
	testing.SetRealm(testing.NewUserRealm(carol))
	WithdrawFor(cross(cur), id)
	sec(5 * day)

	testing.SetRealm(testing.NewUserRealm(dave))
	ClaimAsBackup(cross(cur), id)
	info, _ := GetStream(id)
	uassert.Equal(t, dave, info.Recipient)
}

func TestOnlyTheBackupCanClaim(cur realm, t *testing.T) {
	reset()
	id := newCoinStream(cur, 1000, 0, 100*day, false)

	// No backup set: nobody can claim.
	sec(50 * day)
	testing.SetRealm(testing.NewUserRealm(dave))
	uassert.AbortsWithMessage(t, cur, "driplock: only the stream's backup can claim it",
		func() { ClaimAsBackup(cross(cur), id) })

	testing.SetRealm(testing.NewUserRealm(bob))
	SetBackup(cross(cur), id, dave, MinInactivity)
	sec(2 * day)
	for _, who := range []address{alice, carol, bob} {
		testing.SetRealm(testing.NewUserRealm(who))
		uassert.AbortsWithMessage(t, cur, "driplock: only the stream's backup can claim it",
			func() { ClaimAsBackup(cross(cur), id) })
	}
}

func TestSetBackupRules(cur realm, t *testing.T) {
	reset()
	id := newCoinStream(cur, 1000, 0, 100*day, false)

	testing.SetRealm(testing.NewUserRealm(alice)) // the sender
	uassert.AbortsWithMessage(t, cur, "driplock: only the recipient can set a backup",
		func() { SetBackup(cross(cur), id, alice, 30*day) })

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "driplock: backup must differ from the recipient",
		func() { SetBackup(cross(cur), id, bob, 30*day) })
	uassert.AbortsWithMessage(t, cur, "driplock: inactivity must be between 1 day and 10 years",
		func() { SetBackup(cross(cur), id, dave, day-1) })
	uassert.AbortsWithMessage(t, cur, "driplock: invalid recipient address",
		func() { SetBackup(cross(cur), id, address("nope"), 30*day) })

	SetBackup(cross(cur), id, dave, 30*day)
	SetBackup(cross(cur), id, address(""), 0) // remove it
	sec(60 * day)
	testing.SetRealm(testing.NewUserRealm(dave))
	uassert.AbortsWithMessage(t, cur, "driplock: only the stream's backup can claim it",
		func() { ClaimAsBackup(cross(cur), id) })
}

func TestTransferClearsBackup(cur realm, t *testing.T) {
	reset()
	id := newCoinStream(cur, 1000, 0, 100*day, false)
	testing.SetRealm(testing.NewUserRealm(bob))
	SetBackup(cross(cur), id, dave, MinInactivity)
	TransferRecipient(cross(cur), id, carol)

	sec(10 * day)
	testing.SetRealm(testing.NewUserRealm(dave)) // bob's old backup
	uassert.AbortsWithMessage(t, cur, "driplock: only the stream's backup can claim it",
		func() { ClaimAsBackup(cross(cur), id) })
}
