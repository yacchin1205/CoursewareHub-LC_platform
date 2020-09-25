<?php
require_once __DIR__ . '/../../../lti/vendor/autoload.php';
require_once __DIR__ . '/../../../lib/lti/db.php';
require_once __DIR__ . '/../../../lib/hub-const.php';
require_once __DIR__ . '/../../../lib/functions.php';

use \IMSGlobal\LTI;
$launch = LTI\LTI_Message_Launch::new(new CoursewareHub_Database())
    ->validate();

$mail_address = $launch->get_launch_data()['email'];

session_regenerate_id(true);
// Set Session info
$username = get_username_from_mail_address($mail_address);
$_SESSION['username'] = $username;

header("X-Accel-Redirect: /entrance/");
header("X-Reproxy-URL: ".HUB_URL.'/'.COURSE_NAME."/hub/login");
header("X-REMOTE-USER: $username");
?>
