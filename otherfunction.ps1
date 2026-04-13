# Load the Windows Forms assembly to enable the graphical message box
Add-Type -AssemblyName System.Windows.Forms

# Define the message and the title of the pop-up window
$message = "IM DONE HI hellow this is a test"
$title = "Notification"

# Display the pop-up window
[System.Windows.Forms.MessageBox]::Show($message, $title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
