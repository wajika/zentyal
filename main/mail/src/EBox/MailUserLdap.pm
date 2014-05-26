# Copyright (C) 2005-2007 Warp Networks S.L.
# Copyright (C) 2008-2013 Zentyal S.L.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2, as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
use strict;
use warnings;

package EBox::MailUserLdap;

use base qw(EBox::LdapUserBase);

use EBox::Sudo;
use EBox::Global;
use EBox::Ldap;
use EBox::Validate qw( :all );
use EBox::Exceptions::InvalidData;
use EBox::Exceptions::Internal;
use EBox::Exceptions::DataExists;
use EBox::Exceptions::DataMissing;
use EBox::Exceptions::External;
use EBox::Exceptions::MissingArgument;
use EBox::Model::Manager;
use EBox::Gettext;
use EBox::Users::User;
use TryCatch::Lite;

use Perl6::Junction qw(any);

use constant DIRVMAIL   =>      '/var/vmail/';
use constant SIEVE_SCRIPTS_DIR => '/var/vmail/sieve';
use constant MAX_MAILDIR_BACKUPS => 5;

sub new
{
    my $class = shift;
    my $self  = {};
    $self->{ldap} = EBox::Global->modInstance('users')->ldap();

    bless($self, $class);
    return $self;
}

# Method: mailboxesDir
#
#  Returns:
#    directory where the mailboxes resides
sub mailboxesDir
{
    return DIRVMAIL;
}

# Method: setupUsers
#
#  Set up existent users for working correctly when the module is enabled for
#  first time
sub setupUsers
{
    my ($self) = @_;
    my $userMod = EBox::Global->getInstance()->modInstance('users');

    foreach my $user (@{ $userMod->users() }) {
        my $mail = $user->get('mail');
        if ($mail) {
            my ($lhs, $rhs) = split '@', $mail, 2;
            $self->setUserAccount($user, $lhs, $rhs);
        }
    }
}

# Method: setUserAccount
#
#  This method sets a mail account to a user.
#  The user may be a system user
#
# Parameters:
#
#               user - user object
#               lhs - Either the left hand side of a mail (the foo on foo@bar.baz account) or
#                     the full mail account (don't supply rhs in that case)
#               rhs - the right hand side of a mail (the bar.baz on previous account)

sub setUserAccount
{
    my ($self, $user, $lhs, $rhs)  = @_;
    my $mail = EBox::Global->modInstance('mail');
    my $email;
    if (not $rhs) {
        $email = $lhs;
        ($lhs, $rhs) = split '@', $email, 2;
    } else {
        $email = $lhs . '@' . $rhs;
    }

    EBox::Validate::checkEmailAddress($email, __('mail account'));
    $mail->checkMailNotInUse($email);

    $self->_checkMaildirNotExists($lhs, $rhs);

    my $quota = $mail->defaultMailboxQuota();

    my $hasClass = grep { lc($_) eq 'usereboxmail' } $user->get('objectClass');
    if (not $hasClass) {
        $user->add('objectclass', 'usereboxmail');
    }

    $user->clearCache();

    $user->set('mail', $email, 1);
    $user->set('mailbox', $rhs.'/'.$lhs.'/', 1);
    $user->set('userMaildirSize', 0, 1);
    $user->set('mailquota', $quota, 1);
    $user->set('mailHomeDirectory', DIRVMAIL, 1);
    $user->save();

    $self->_createMaildir($lhs, $rhs);

    my @list = $mail->{malias}->listMailGroupsByUser($user);
    foreach my $item(@list) {
        my @aliases = @{ $mail->{malias}->groupAliases($item) };
        foreach my $alias (@aliases) {
            $mail->{malias}->addMaildrop($alias, $email);
        }
    }
}

# Method: delUserAccount
#
#  This method removes a mail account to a user
#
# Parameters:
#
#               user - user object
#               usermail - the user's mail address (optional)
sub delUserAccount
{
    my ($self, $user, $usermail) = @_;
    ($self->_accountExists($user)) or return;
    if (not defined $usermail) {
        $usermail = $self->userAccount($user);
    }

    my $mail = EBox::Global->modInstance('mail');
    # First we remove all mail aliases asociated with the user account.
    foreach my $alias ($mail->{malias}->accountAlias($usermail)) {
                $mail->{malias}->delAlias($alias);
            }

    # Remove mail account from group alias maildrops
    foreach my $alias ($mail->{malias}->groupAccountAlias($usermail)) {
        $mail->{malias}->delMaildrop($alias,$usermail);
    }

    # get the mailbox attribute for later use..
    my $mailbox = $user->get('mailbox');

    $user->remove('objectClass', 'usereboxmail', 1);
    $user->delete('mail', 1);
    $user->delete('mailbox', 1);
    $user->delete('userMaildirSize', 1);
    $user->delete('mailquota', 1);
    $user->delete('mailHomeDirectory', 1);
    $user->save();

    my @cmds;

    # Here we remove mail directorie of user account.
    push (@cmds, '/bin/rm -rf ' . DIRVMAIL . $mailbox);

    # remove user's sieve scripts dir
    my ($lhs, $rhs) = split '@', $usermail;
    my $sieveDir   = $self->_sieveDir($usermail, $rhs);
    push (@cmds, "/bin/rm -rf $sieveDir");

    EBox::Sudo::root(@cmds);

    # disable openchange account if exists. We don't implement and observer
    # notifier interface bz only one module is to be notifier
    if ($self->openchangeAccountEnabled($user)) {
        my $openchange =  EBox::Global->modInstance('openchange');
        my $userOc = $openchange->_ldapModImplementation();
        if ($userOc->enabled($user)) {
            $userOc->setAccountEnabled($user, 0);
        }
    }
}

# Method: userAccount
#
#  return the user mail account or undef if it doesn't exists
#
sub userAccount
{
    my ($self, $user) = @_;

    return $user->get('mail');
}

# Method: userByAccount
#
#    given an account returns the user that has it assigened. It does not work
#    with alias. (I suggest to use EBox::MailAliasLdap::getAccountsByAlias or
#    EBox::MailAliasLdap::getAccountsByAlia::aliasExist) before to take care of
#    alias)
#
#   Params:
#       account -email account
#
#   Returns:
#          the user or undef if there is not account
# TODO: REVIEW
sub userByAccount
{
    my ($self, $account) = @_;

    my $mail = EBox::Global->modInstance('mail');

    my %args = (
                base => $self->{ldap}->dn(),
                filter => "&(objectclass=person)(mail=$account)",
                scope => 'sub',
                attrs => ['samAccountName'],
               );

    my $result = $self->{ldap}->search(\%args);
    if ($result->count() == 0) {
        return undef;
    }

    my $entry = $result->entry(0);
    my $usermail = $entry->get_value('samAccountName');

    return $usermail;
}

# Method: delAccountsFromVDomain
#
#  This method removes all mail accounts from a virtual domain
#
# Parameters:
#
#               vdomain - the virtual domain name
sub delAccountsFromVDomain   #vdomain
{
    my ($self, $vdomain) = @_;

    my %accs = %{$self->allAccountsFromVDomain($vdomain)};

    my $mail = "";
    while (my ($uid, $mail) = each %accs) {
        my $user = new EBox::Users::User(uid => $uid);
        $mail = $accs{$uid};

        $self->delUserAccount($user, $accs{$uid});
    }
}

# Method: _addUser
#
#   Overrides <EBox::Users::LdapUserBase> to create a default mail
#   account user@domain if the admin has enabled the auto email account creation
#   feature
sub _addUser
{
    my ($self, $user, $passwd) = @_;

    return unless (EBox::Global->modInstance('mail')->configured());

    my $mail = EBox::Global->modInstance('mail');
    my @vdomains = $mail->{vdomains}->vdomains();
    return unless (@vdomains);

    my $model = $mail->model('MailUser');
    return unless ($model->enabledValue());
    my $vdomain = $model->domainValue();
    return unless ($vdomain and $mail->{vdomains}->vdomainExists($vdomain));

    try {
        $self->setUserAccount($user, lc($user->name()), $vdomain);
    } catch {
       EBox::info("Creation of email account for $user failed");
    }
}

sub _delGroup
{
    my ($self, $group) = @_;
    my $mail = EBox::Global->modInstance('mail');

    return unless ($mail->configured());

    my @groupAliases = @{ $mail->{malias}->groupAliases($group) };
    foreach my $alias (@groupAliases) {
        $mail->{malias}->delAlias($alias);
    }
}

sub _delGroupWarning
{
    my ($self, $group) = @_;

    return unless (EBox::Global->modInstance('mail')->configured());

    my $mail = EBox::Global->modInstance('mail');

    my $txt = __('This group has a mail alias');

    if ($mail->{malias}->groupHasAlias($group)) {
        return ($txt);
    }

    return undef;
}

sub _delUser
{
    my ($self, $user) = @_;

    return unless (EBox::Global->modInstance('mail')->configured());

    $self->delUserAccount($user);
}

sub _delUserWarning
{
    my ($self, $user) = @_;

    return unless (EBox::Global->modInstance('mail')->configured());

    my $txt = __('This user has a mail account');

    if ($self->_accountExists($user)) {
        return ($txt);
    }

    return undef;
}

sub _userAddOns
{
    my ($self, $user) = @_;

    my $mail = EBox::Global->modInstance('mail');

    return undef unless ($mail->configured());

    my $usermail = $self->userAccount($user);
    my @aliases = $mail->{malias}->accountAlias($usermail);
    my @vdomains =  $mail->{vdomains}->vdomains();
    my $quotaType = $self->maildirQuotaType($user);
    my $quota   = $self->maildirQuota($user);

    # fetchmail disabled
    # my $externalRetrievalEnabled = $mail->model('RetrievalServices')->value('fetchmail');
    # my @externalAccounts = map {
    #     $mail->{fetchmail}->externalAccountRowValues($_)
    #  } @{ $mail->{fetchmail}->externalAccountsForUser($user) };

    my @paramsList = (
            user        => $user,
            mail        => $usermail,
            aliases     => \@aliases,
            vdomains    => \@vdomains,

            maildirQuotaType => $quotaType,
            maildirQuota => $quota,

            service => $mail->service,
    );

    my $title;
    if  (not @vdomains) {
        $title = __('Mail account');
    } elsif (not $usermail) {
        $title =  __('Create mail account');
    } else {
        $title = __('Mail account settings');
    }

    return {
        title  => $title,
        path   => '/mail/account.mas',
        params => { @paramsList }
       };
}

sub _groupAddOns
{
    my ($self, $group) = @_;

    return unless (EBox::Global->modInstance('mail')->configured());

    my $mail = EBox::Global->modInstance('mail');
    my $aliases = $mail->{malias}->groupAliases($group);
    my @vd =  $mail->{vdomains}->vdomains();

    my $groupEmpty    = 1;
    my $usersWithMail = 0;
    foreach my $user (@{ $group->members() }) {
        $groupEmpty = 0;
        if ($self->userAccount($user)) {
            $usersWithMail = 1;
            last;
        }
    }

    my $args = {
        'group'    => $group,
        'vdomains' => \@vd,
        'aliases'  => $aliases,
        'service'  => $mail->service(),
        'groupEmpty' => $groupEmpty,
        'usersWithMail' => $usersWithMail,
    };

    return {
        title  => __('Mail alias settings'),
        path   => '/mail/groupalias.mas',
        params => $args
       };
}

sub _modifyGroup
{
    my ($self, $group) = @_;

    return unless (EBox::Global->modInstance('mail')->configured());

    my $mail = EBox::Global->modInstance('mail');
    $mail->{malias}->updateGroupAliases($group);
}

# Method: _accountExists
#
#  This method returns if a user have a mail account
#
# Parameters:
#
#               user - user object
# Returns:
#
#               bool - true if user have mail account
sub _accountExists
{
    my ($self, $user) = @_;

    my $username = $user->name();
    my %attrs = (
                 base => $self->{ldap}->dn(),
                 filter => "&(objectclass=userEBoxMail)(samAccountName=$username)",
                 scope => 'sub'
                );

    my $result = $self->{ldap}->search(\%attrs);

    return ($result->count > 0);
}

# Method: allAccountFromVDomain
#
#  This method returns all accounts from a virtual domain
#
# Parameters:
#
#               vdomain - The Virtual domain name
#
# Returns:
#
#               hash ref - with (uid, mail) pairs of the virtual domain
sub allAccountsFromVDomain
{
    my ($self, $vdomain) = @_;

    my %attrs = (
                 base => $self->{ldap}->dn(),
                 filter => "&(objectclass=person)(mail=*@".$vdomain.")",
                 scope => 'sub'
                );

    my $result = $self->{ldap}->search(\%attrs);

    my %accounts = map { $_->get_value('samAccountName'), $_->get_value('mail')} $result->sorted('uid');

    return \%accounts;
}

# Method: usersWithMailInGroup
#
#  This method returns the list of users with mail account on the group
#
# Parameters:
#
#  group - group object
#
sub usersWithMailInGroup
{
    my ($self, $group) = @_;

    my $groupdn = $group->dn();
    my %args = (
        base => $self->{ldap}->dn(),
        filter => "(&(objectclass=userEBoxMail)(memberof=$groupdn))",
        scope => 'sub',
    );

    my $result = $self->{ldap}->search(\%args);

    my $usersMod = EBox::Global->modInstance('users');
    my @mailusers;
    foreach my $entry ($result->entries()) {
        my $object = $usersMod->entryModeledObject($entry);
        push (@mailusers, $object) if ($object);
    }

    return @mailusers;
}

# Method: checkUserMDSize
#
#  This method returns all users that should be warned about a reduction on the
#  maildir size
#
# Parameters:
#
#               vdomain - The Virtual domain name
#               newmdsize - The new maildir size
sub checkUserMDSize
{
    my ($self, $vdomain, $newmdsize) = @_;

    my %accounts = %{$self->allAccountsFromVDomain($vdomain)};
    my @warnusers = ();
    my $size = 0;

    foreach my $acc (keys %accounts) {
        $size = $self->maildirQuota($acc);
                ($size > $newmdsize) and push (@warnusers, $acc);
    }

    return \@warnusers;
}

sub _checkMaildirNotExists
{
    my ($self, $lhs, $vdomain) = @_;
    my $dir = DIRVMAIL . "/$vdomain/$lhs/";

    if (EBox::Sudo::fileTest('-e', $dir)) {
        my $backupDirBase = $dir ;
        $backupDirBase =~ s{/$}{};
        $backupDirBase .= '.bak';

        my $counter = 1;
        my $backupDir = $backupDirBase . '.' . $counter;
        while (EBox::Sudo::fileTest('-e', $backupDir)) {
            $counter += 1;
            if ($counter <= MAX_MAILDIR_BACKUPS) {
                $backupDir = $backupDirBase . '.' . $counter;
            } else {
                EBox::error("Maximum number of backup directories for $dir reached. We will remove the last one ($backupDir) and use it again");
                EBox::Sudo::root("rm -rf $backupDir");
                last;
            }
        }

        EBox::Sudo::root("mv $dir $backupDir");
        EBox::warn("Mail directory $dir already existed, moving it to $backupDir");
    }
}

# Method: _createMaildir
#
#  This method creates the maildir of an account
#
# Parameters:
#
#               lhs - left hand side of an account (foo on foo@bar.baz)
#               vdomain - Virtual Domain name
sub _createMaildir
{
    my ($self, $lhs, $vdomain) = @_;
    my $vdomainDir = "/var/vmail/$vdomain";
    my $userDir   =  "$vdomainDir/$lhs/";

    my @cmds;
    push (@cmds, '/bin/mkdir -p /var/vmail');
    push (@cmds, '/bin/chmod 2775 /var/mail/');
    push (@cmds, '/bin/chown ebox.ebox /var/vmail/');

    push (@cmds, "/bin/mkdir -p $vdomainDir");
    push (@cmds, "/bin/chown ebox.ebox $vdomainDir");
    push (@cmds, "/usr/bin/maildirmake.dovecot $userDir ebox");
    push (@cmds, "/bin/chown ebox.ebox -R $userDir");
    EBox::Sudo::root(@cmds);
}

sub _sieveDir
{
    my ($self, $lhs, $vdomain) = @_;
    return SIEVE_SCRIPTS_DIR . "/$vdomain/$lhs";
}

#  Method: maildir
#
#     get the maildir which will be used by the given account
#
#   Parameters:
#               lhs - left hand side of an account (foo on foo@bar.baz)
#               vdomain - Virtual Domain name
#
#   Returns:
#         full path of the maildir
sub maildir
{
    my ($class, $lhs, $vdomain) = @_;

    return "/var/vmail/$vdomain/$lhs/";
}

#  Method: maildirQuota
#
#     get the maildir quota for the user, please note that is only the quota
#     amount this does not signals wether it is a default quota or a custom quota
#
#   Parameters:
#        user - name of the user
sub maildirQuota
{
    my ($self, $user) = @_;
    return $user->get('mailquota');
}

#  Method: maildirQuotaType
#
#     get the type of the quota assigned to the user
#
#   Parameters:
#        user - name of the user
#
#    Returns:
#       one of this strings:
#          'default' - uses default quota type
#          'noQuota' - the user has a custom unlimtied quota
#          'custom'  - the user has a non-unlimted custom quota
sub maildirQuotaType
{
    my ($self, $user)  = @_;

    my $userQuota = $user->get('userMaildirSize');
    if (not $userQuota) {
        return 'default';
    }

    my $quota = $self->maildirQuota($user);
    if ($quota == 0) {
        return 'noQuota';
    } else {
        return 'custom';
    }

    return 'default';
}

#  Method: setMaildirQuotaUsesDefault
#
#     sets wether the user is using the default quota or not. Additionally if
#     user is set to use the default quota the quota value is synchronized with
#     the default quota
#
#   Parameters:
#        user - name of the user
#        isDefault - wether the user is using the default quota
sub setMaildirQuotaUsesDefault
{
    my ($self, $user, $isDefault) = @_;

    my $userMaildirSizeValue = $isDefault ? 0 : 1;
    $user->set('userMaildirSize', $userMaildirSizeValue, 1);
    if ($isDefault) {
        # sync quota with default
        my $mail = EBox::Global->modInstance('mail');
        my $defaultQuota = $mail->defaultMailboxQuota();
        $user->set('mailquota', $defaultQuota, 1);
    }
    $user->save();
}

#  Method: setMaildirQuota
#
#     sets the quota value for a user. Do not use it with users which use
#     default quota; in this case use only setMaildirQuotaUsesDefault
#
#   Parameters:
#        user - name of the user
#        quota - numeric value of the quota in Mb
sub setMaildirQuota
{
    my ($self, $user, $quota) = @_;
    defined $user or
        throw EBox::Exceptions::MissingArgument('user');
    defined $quota or
        throw EBox::Exceptions::MissingArgument('quota');

    if (not $self->userAccount($user)) {
        throws EBox::Exceptions::Internal(
             "User $user->name has not mail account"
           );
    }

    if ($quota < 0) {
        throw EBox::Exceptions::External(
            __('Quota can only be a positive number or zero for unlimited quota')
           )
    }

    $user->set('mailquota', $quota);
}

#  Method: regenMaildirQuotas
#
# regenerate user accounts mailquotas to reflect the changes in default
# quota configuration (only if default quota has changed)
sub regenMaildirQuotas
{
    my ($self) = @_;

    my $mail = EBox::Global->modInstance('mail');
    my $defaultQuota = $mail->defaultMailboxQuota();

    # Check mailbox size against last saved value
    my $prevDefaultQuota = $mail->get_int('prevMailboxSize');

    # Only regenerate if default quota has changed (or first time)
    return if (defined($prevDefaultQuota) and ($defaultQuota eq $prevDefaultQuota));

    EBox::info("Changing default quota to $defaultQuota MB");

    # Save new value
    $mail->set_int('prevMailboxSize', $defaultQuota);
    $mail->_saveConfig();

    my $usersMod = EBox::Global->modInstance('users');

    foreach my $user (@{$usersMod->users()}) {
        my $username = $user->name();
        $self->userAccount($user) or next;

        if ($self->maildirQuotaType($user) eq 'default') {
            $self->setMaildirQuota($user, $defaultQuota);
        }
    }
}

# Method: gidvmail
#
#  This method returns the gid value of ebox user
#
sub gidvmail
{
    my ($self) = @_;
    return scalar (getgrnam(EBox::Config::group));
}

# Method: uidvmail
#
#  This method returns the uid value of ebox user
#
sub uidvmail
{
    my ($self) = @_;

    return scalar (getpwnam(EBox::Config::user));
}

# Method: defaultUserModel
#
#   Overrides <EBox::UsersAndGrops::LdapUserBase::defaultUserModel>
#   to return our default user template
sub defaultUserModel
{
    return 'mail/MailUser';
}

# Method: multipleOUSupport
#
#   Returns 1 if this module supports users in multiple OU's,
#   0 otherwise
#
sub multipleOUSupport
{
    return 1;
}

# Method: hiddenOUs
#
#   Returns the list of OUs to hide on the UI
#
sub hiddenOUs
{
    return [ 'postfix' ];
}

sub openchangeAccountEnabled
{
    my ($self, $user) = @_;
    if (EBox::Global->modExists('openchange')) {
        my $openchange =  EBox::Global->modInstance('openchange');
        if ($openchange->configured() and $openchange->isProvisioned()) {
            my $userOc = $openchange->_ldapModImplementation();
            return $userOc->enabled($user);
        }
    }
    return 0;
}



1;
